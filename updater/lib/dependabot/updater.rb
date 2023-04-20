# frozen_string_literal: true

require "dependabot/dependency_change"
require "dependabot/dependency_change_builder"
require "dependabot/environment"
require "dependabot/experiments"
require "dependabot/file_fetchers"
require "dependabot/logger"
require "dependabot/python"
require "dependabot/terraform"
require "dependabot/elm"
require "dependabot/docker"
require "dependabot/git_submodules"
require "dependabot/github_actions"
require "dependabot/composer"
require "dependabot/nuget"
require "dependabot/gradle"
require "dependabot/maven"
require "dependabot/hex"
require "dependabot/cargo"
require "dependabot/go_modules"
require "dependabot/npm_and_yarn"
require "dependabot/bundler"
require "dependabot/pub"

require "dependabot/updater/error_handler"
require "dependabot/updater/operations"
require "dependabot/updater/security_update_helpers"
require "dependabot/security_advisory"
require "dependabot/update_checkers"
require "wildcard_matcher"

module Dependabot
  class Updater
    # FIXME: Remove this once we deprecate the legacy_run code path
    include SecurityUpdateHelpers
    class SubprocessFailed < StandardError
      attr_reader :raven_context

      def initialize(message, raven_context:)
        super(message)

        @raven_context = raven_context
      end
    end

    # To do work, this class needs three arguments:
    # - The Dependabot::Service to send events and outcomes to
    # - The Dependabot::Job that describes the work to be done
    # - The Dependabot::DependencySnapshot which encapsulates the starting state of the project
    def initialize(service:, job:, dependency_snapshot:)
      @service = service
      @job = job
      @dependency_snapshot = dependency_snapshot
      @error_handler = ErrorHandler.new(service: service, job: job)
      # TODO: Collect @created_pull_requests on the Job object?
      @created_pull_requests = []
    end

    def run
      return unless job
      return legacy_run unless (operation_class = Operations.class_for(job: job))

      Dependabot.logger.debug("Performing job with #{operation_class}")
      service.increment_metric("updater.started", tags: { operation: operation_class.tag_name })
      operation_class.new(
        service: service,
        job: job,
        dependency_snapshot: dependency_snapshot,
        error_handler: error_handler
      ).perform
    rescue *ErrorHandler::RUN_HALTING_ERRORS.keys => e
      # TODO: Drop this into Security-specific operations
      if e.is_a?(Dependabot::AllVersionsIgnored) && !job.security_updates_only?
        error = StandardError.new(
          "Dependabot::AllVersionsIgnored was unexpectedly raised for a non-security update job"
        )
        error.set_backtrace(e.backtrace)
        service.capture_exception(error: error, job: job)
        return
      end

      # OOM errors are special cased so that we stop the update run early
      service.record_update_job_error(
        error_type: ErrorHandler::RUN_HALTING_ERRORS.fetch(e.class),
        error_details: nil
      )
    end

    private

    attr_accessor :created_pull_requests
    attr_reader :service, :job, :dependency_snapshot, :error_handler

    # This is the original logic within run, we currently fail over to this if
    # no Operation class exists for the given job.
    def legacy_run
      service.increment_metric("updater.started", tags: { operation: "Legacy" })
      if job.updating_a_pull_request?
        Dependabot.logger.info("Starting PR update job for #{job.source.repo}")
        check_and_update_existing_pr_with_error_handling(dependencies)
      else
        Dependabot.logger.info("Starting update job for #{job.source.repo}")
        dependencies.each { |dep| check_and_create_pr_with_error_handling(dep) }
      end
    end

    def check_and_create_pr_with_error_handling(dependency)
      check_and_create_pull_request(dependency)
    rescue Dependabot::InconsistentRegistryResponse => e
      error_handler.log_error(
        dependency: dependency,
        error: e,
        error_type: "inconsistent_registry_response",
        error_detail: e.message
      )
    rescue StandardError => e
      error_handler.handle_dependabot_error(error: e, dependency: dependency)
    end

    def check_and_update_existing_pr_with_error_handling(dependencies)
      dependency = dependencies.last
      check_and_update_pull_request(dependencies)
    rescue StandardError => e
      error_handler.handle_dependabot_error(error: e, dependency: dependency)
    end

    # rubocop:disable Metrics/AbcSize
    # rubocop:disable Metrics/PerceivedComplexity
    # rubocop:disable Metrics/MethodLength
    def check_and_update_pull_request(dependencies)
      if dependencies.count != job.dependencies.count
        # If the job dependencies mismatch the parsed dependencies, then
        # we should close the PR as at least one thing we changed has been
        # removed from the project.
        close_pull_request(reason: :dependency_removed)
        return
      end

      # NOTE: Prevent security only updates from turning into latest version
      # updates if the current version is no longer vulnerable. This happens
      # when a security update is applied by the user directly and the existing
      # pull request is rebased.
      if job.security_updates_only? &&
         dependencies.none? { |d| job.allowed_update?(d) }
        lead_dependency = dependencies.first
        if job.vulnerable?(lead_dependency)
          Dependabot.logger.info(
            "Dependency no longer allowed to update #{lead_dependency.name} #{lead_dependency.version}"
          )
        else
          Dependabot.logger.info("No longer vulnerable #{lead_dependency.name} #{lead_dependency.version}")
        end
        close_pull_request(reason: :up_to_date)
        return
      end

      # The first dependency is the "lead" dependency in a multi-dependency
      # update - i.e., the one we're trying to update.
      #
      # Note: Gradle, Maven and Nuget dependency names can be case-insensitive
      # and the dependency name in the security advisory often doesn't match
      # what users have specified in their manifest.
      lead_dep_name = job.dependencies.first.downcase
      lead_dependency = dependencies.find do |dep|
        dep.name.downcase == lead_dep_name
      end
      checker = update_checker_for(lead_dependency, raise_on_ignored: raise_on_ignored?(lead_dependency))
      log_checking_for_update(lead_dependency)

      return if all_versions_ignored?(lead_dependency, checker)

      return close_pull_request(reason: :up_to_date) if checker.up_to_date?

      requirements_to_unlock = requirements_to_unlock(checker)
      log_requirements_for_update(requirements_to_unlock, checker)

      return close_pull_request(reason: :update_no_longer_possible) if requirements_to_unlock == :update_not_possible

      updated_deps = checker.updated_dependencies(
        requirements_to_unlock: requirements_to_unlock
      )

      dependency_change = Dependabot::DependencyChangeBuilder.create_from(
        job: job,
        dependency_files: dependency_snapshot.dependency_files,
        updated_dependencies: updated_deps,
        change_source: checker.dependency
      )

      # NOTE: Gradle, Maven and Nuget dependency names can be case-insensitive
      # and the dependency name in the security advisory often doesn't match
      # what users have specified in their manifest.
      job_dependencies = job.dependencies.map(&:downcase)
      if dependency_change.updated_dependencies.map(&:name).map(&:downcase) != job_dependencies
        # The dependencies being updated have changed. Close the existing
        # multi-dependency PR and try creating a new one.
        close_pull_request(reason: :dependencies_changed)
        create_pull_request(dependency_change)
      elsif existing_pull_request(dependency_change.updated_dependencies)
        # The existing PR is for this version. Update it.
        update_pull_request(dependency_change)
      else
        # The existing PR is for a previous version. Supersede it.
        create_pull_request(dependency_change)
      end
    end
    # rubocop:enable Metrics/AbcSize
    # rubocop:enable Metrics/PerceivedComplexity
    # rubocop:enable Metrics/MethodLength

    # rubocop:disable Metrics/AbcSize
    # rubocop:disable Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/PerceivedComplexity
    # rubocop:disable Metrics/MethodLength
    def check_and_create_pull_request(dependency)
      checker = update_checker_for(dependency, raise_on_ignored: raise_on_ignored?(dependency))

      log_checking_for_update(dependency)

      return if all_versions_ignored?(dependency, checker)

      # If the dependency isn't vulnerable or we can't know for sure we won't be
      # able to know if the updated dependency fixes any advisories
      if job.security_updates_only?
        unless checker.vulnerable?
          # The current dependency isn't vulnerable if the version is correct and
          # can be matched against the advisories affected versions
          if checker.version_class.correct?(checker.dependency.version)
            return record_security_update_not_needed_error(checker)
          end

          return record_dependency_file_not_supported_error(checker)
        end
        return record_security_update_ignored(checker) unless job.allowed_update?(dependency)
      end

      if checker.up_to_date?
        # The current version is still vulnerable and  Dependabot can't find a
        # published or compatible non-vulnerable version, this can happen if the
        # fixed version hasn't been published yet or the published version isn't
        # compatible with the current enviroment (e.g. python version) or
        # version (uses a different version suffix for gradle/maven)
        return record_security_update_not_found(checker) if job.security_updates_only?

        return log_up_to_date(dependency)
      end

      if pr_exists_for_latest_version?(checker)
        record_pull_request_exists_for_latest_version(checker) if job.security_updates_only?
        return Dependabot.logger.info(
          "Pull request already exists for #{checker.dependency.name} " \
          "with latest version #{checker.latest_version}"
        )
      end

      requirements_to_unlock = requirements_to_unlock(checker)
      log_requirements_for_update(requirements_to_unlock, checker)

      if requirements_to_unlock == :update_not_possible
        return record_security_update_not_possible_error(checker) if job.security_updates_only? && job.dependencies

        return Dependabot.logger.info(
          "No update possible for #{dependency.name} #{dependency.version}"
        )
      end

      updated_deps = checker.updated_dependencies(
        requirements_to_unlock: requirements_to_unlock
      )

      # Prevent updates that don't end up fixing any security advisories,
      # blocking any updates where dependabot-core updates to a vulnerable
      # version. This happens for npm/yarn subdendencies where Dependabot has no
      # control over the target version. Related issue:
      # https://github.com/github/dependabot-api/issues/905
      if job.security_updates_only? &&
         updated_deps.none? { |d| job.security_fix?(d) }
        return record_security_update_not_possible_error(checker)
      end

      if (existing_pr = existing_pull_request(updated_deps))
        # Create a update job error to prevent dependabot-api from creating a
        # update_not_possible error, this is likely caused by a update job retry
        # so should be invisible to users (as the first job completed with a pull
        # request)
        record_pull_request_exists_for_security_update(existing_pr) if job.security_updates_only?

        deps = existing_pr.map do |dep|
          if dep.fetch("dependency-removed", false)
            "#{dep.fetch('dependency-name')}@removed"
          else
            "#{dep.fetch('dependency-name')}@#{dep.fetch('dependency-version')}"
          end
        end

        return Dependabot.logger.info(
          "Pull request already exists for #{deps.join(', ')}"
        )
      end

      if peer_dependency_should_update_instead?(checker.dependency.name, updated_deps)
        return Dependabot.logger.info(
          "No update possible for #{dependency.name} #{dependency.version} " \
          "(peer dependency can be updated)"
        )
      end

      dependency_change = Dependabot::DependencyChangeBuilder.create_from(
        job: job,
        dependency_files: dependency_snapshot.dependency_files,
        updated_dependencies: updated_deps,
        change_source: checker.dependency
      )
      create_pull_request(dependency_change)
    end
    # rubocop:enable Metrics/MethodLength
    # rubocop:enable Metrics/AbcSize
    # rubocop:enable Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/PerceivedComplexity

    def raise_on_ignored?(dependency)
      job.security_updates_only? || job.ignore_conditions_for(dependency).any?
    end

    def requirements_to_unlock(checker)
      if job.lockfile_only? || !checker.requirements_unlocked_or_can_be?
        if checker.can_update?(requirements_to_unlock: :none) then :none
        else
          :update_not_possible
        end
      elsif checker.can_update?(requirements_to_unlock: :own) then :own
      elsif checker.can_update?(requirements_to_unlock: :all) then :all
      else
        :update_not_possible
      end
    end

    # If a version update for a peer dependency is possible we should
    # defer to the PR that will be created for it to avoid duplicate PRs.
    def peer_dependency_should_update_instead?(dependency_name, updated_deps)
      # This doesn't apply to security updates as we can't rely on the
      # peer dependency getting updated.
      return false if job.security_updates_only?

      updated_deps.
        reject { |dep| dep.name == dependency_name }.
        any? do |dep|
          next true if existing_pull_request([dep])

          original_peer_dep = ::Dependabot::Dependency.new(
            name: dep.name,
            version: dep.previous_version,
            requirements: dep.previous_requirements,
            package_manager: dep.package_manager
          )
          update_checker_for(original_peer_dep, raise_on_ignored: false).
            can_update?(requirements_to_unlock: :own)
        end
    end

    def log_checking_for_update(dependency)
      Dependabot.logger.info(
        "Checking if #{dependency.name} #{dependency.version} needs updating"
      )
      job.log_ignore_conditions_for(dependency)
    end

    def all_versions_ignored?(dependency, checker)
      Dependabot.logger.info("Latest version is #{checker.latest_version}")
      false
    rescue Dependabot::AllVersionsIgnored
      Dependabot.logger.info("All updates for #{dependency.name} were ignored")

      # Report this error to the backend to create an update job error
      raise if job.security_updates_only?

      true
    end

    def log_up_to_date(dependency)
      Dependabot.logger.info(
        "No update needed for #{dependency.name} #{dependency.version}"
      )
    end

    def log_requirements_for_update(requirements_to_unlock, checker)
      Dependabot.logger.info("Requirements to unlock #{requirements_to_unlock}")

      return unless checker.respond_to?(:requirements_update_strategy)

      Dependabot.logger.info(
        "Requirements update strategy #{checker.requirements_update_strategy}"
      )
    end

    def pr_exists_for_latest_version?(checker)
      latest_version = checker.latest_version&.to_s
      return false if latest_version.nil?

      job.existing_pull_requests.
        select { |pr| pr.count == 1 }.
        map(&:first).
        select { |pr| pr.fetch("dependency-name") == checker.dependency.name }.
        any? { |pr| pr.fetch("dependency-version", nil) == latest_version }
    end

    def existing_pull_request(updated_dependencies)
      new_pr_set = Set.new(
        updated_dependencies.map do |dep|
          {
            "dependency-name" => dep.name,
            "dependency-version" => dep.version,
            "dependency-removed" => dep.removed? ? true : nil
          }.compact
        end
      )

      job.existing_pull_requests.find { |pr| Set.new(pr) == new_pr_set } ||
        created_pull_requests.find { |pr| Set.new(pr) == new_pr_set }
    end

    def dependencies
      # Rebases and security updates have dependencies, version updates don't
      return dependency_snapshot.job_dependencies if job.dependencies

      if dependency_snapshot.dependencies.any? && dependency_snapshot.allowed_dependencies.none?
        Dependabot.logger.info("Found no dependencies to update after filtering allowed updates")
        return []
      end

      allowed_deps = dependency_snapshot.allowed_dependencies
      # Return dependencies in a random order, with top-level dependencies
      # considered first so that dependency runs which time out don't always hit
      # the same dependencies
      allowed_deps = allowed_deps.shuffle unless Environment.deterministic_updates?

      # Consider updating vulnerable deps first. Only consider the first 10,
      # though, to ensure they don't take up the entire update run
      deps = allowed_deps.select { |d| job.vulnerable?(d) }.sample(10) +
             allowed_deps.reject { |d| job.vulnerable?(d) }

      deps
    end

    def update_checker_for(dependency, raise_on_ignored:)
      Dependabot::UpdateCheckers.for_package_manager(job.package_manager).new(
        dependency: dependency,
        dependency_files: dependency_snapshot.dependency_files,
        repo_contents_path: job.repo_contents_path,
        credentials: job.credentials,
        ignored_versions: job.ignore_conditions_for(dependency),
        security_advisories: job.security_advisories_for(dependency),
        raise_on_ignored: raise_on_ignored,
        requirements_update_strategy: job.requirements_update_strategy,
        options: job.experiments
      )
    end

    def create_pull_request(dependency_change)
      Dependabot.logger.info("Submitting #{dependency_change.updated_dependencies.map(&:name).join(', ')} " \
                             "pull request for creation")

      service.create_pull_request(dependency_change, dependency_snapshot.base_commit_sha)

      created_pull_requests << dependency_change.updated_dependencies.map do |dep|
        {
          "dependency-name" => dep.name,
          "dependency-version" => dep.version,
          "dependency-removed" => dep.removed? ? true : nil
        }.compact
      end
    end

    def update_pull_request(dependency_change)
      Dependabot.logger.info("Submitting #{dependency_change.updated_dependencies.map(&:name).join(', ')} " \
                             "pull request for update")

      service.update_pull_request(dependency_change, dependency_snapshot.base_commit_sha)
    end

    def close_pull_request(reason:)
      reason_string = reason.to_s.tr("_", " ")
      Dependabot.logger.info("Telling backend to close pull request for " \
                             "#{job.dependencies.join(', ')} - #{reason_string}")
      service.close_pull_request(job.dependencies, reason)
    end
  end
end
