# frozen_string_literal: true

require "dependabot/npm_and_yarn/file_parser"
require "dependabot/npm_and_yarn/helpers"
require "dependabot/shared_helpers"

module Dependabot
  module NpmAndYarn
    class FileUpdater
      class PnpmLockfileUpdater
        require_relative "package_json_updater"

        def initialize(dependencies:, dependency_files:, repo_contents_path:, credentials:)
          @dependencies = dependencies
          @dependency_files = dependency_files
          @repo_contents_path = repo_contents_path
          @credentials = credentials
        end

        def updated_pnpm_lock_content(pnpm_lock)
          @updated_pnpm_lock_content ||= {}
          return @updated_pnpm_lock_content[pnpm_lock.name] if @updated_pnpm_lock_content[pnpm_lock.name]

          new_content = run_pnpm_update(pnpm_lock: pnpm_lock)
          @updated_pnpm_lock_content[pnpm_lock.name] = new_content
        end

        private

        attr_reader :dependencies, :dependency_files, :repo_contents_path, :credentials

        def top_level_dependencies
          dependencies.select(&:top_level?)
        end

        def sub_dependencies
          dependencies.reject(&:top_level?)
        end

        def run_pnpm_update(pnpm_lock:)
          SharedHelpers.in_a_temporary_repo_directory(base_dir, repo_contents_path) do
            write_temporary_dependency_files

            SharedHelpers.with_git_configured(credentials: credentials) do
              run_pnpm_top_level_updater(pnpm_lock: pnpm_lock)
            end
          end
        end

        def run_pnpm_top_level_updater(pnpm_lock:)
          top_level_requirements = top_level_dependencies.map { |dependency| "#{dependency.name}@#{dependency.version}" }.join(" ")

          previous_package_files_contents = package_files_contents

          updated_lockfile_content = update_lockfile(
            command: "pnpm install #{top_level_requirements} --lockfile-only --ignore-workspace-root-check",
            pnpm_lock: pnpm_lock
          )

          return updated_lockfile_content unless previous_package_files_contents != package_files_contents

          package_files.zip(previous_package_files_contents).each do |file, previous_content|
            File.write(file.name, previous_content)
          end

          update_lockfile(
            command: "pnpm install --lockfile-only",
            pnpm_lock: pnpm_lock
          )
        end

        def update_lockfile(command:, pnpm_lock:, env: {})
          SharedHelpers.run_shell_command(
            command,
            env: env
          )

          File.read(pnpm_lock.name)
        end

        def write_temporary_dependency_files
          package_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)

            updated_content =
              if top_level_dependencies.any?
                updated_package_json_content(file)
              else
                file.content
              end

            File.write(file.name, updated_content)
          end
        end

        def updated_package_json_content(file)
          @updated_package_json_content ||= {}
          @updated_package_json_content[file.name] ||=
            PackageJsonUpdater.new(
              package_json: file,
              dependencies: top_level_dependencies
            ).updated_package_json.content
        end

        def package_files
          @package_files ||= dependency_files.select { |f| f.name.end_with?("package.json") }
        end

        def package_files_contents
          package_files.map { |file| File.read(file.name) }
        end

        def base_dir
          dependency_files.first.directory
        end

        def supports_dedupe?
          Version.new(pnpm_version) >= Version.new("7.26.0")
        end

        def pnpm_version
          @pnpm_version ||= SharedHelpers.run_shell_command("pnpm --version").strip
        end
      end
    end
  end
end
