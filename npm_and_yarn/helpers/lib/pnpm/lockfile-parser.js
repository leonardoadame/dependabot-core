/* PNPM-LOCK.YAML PARSER
 *
 * Inputs:
 *  - directory containing a pnpm-lock.yaml file
 *
 * Outputs:
 *  - JSON formatted information of dependencies (name, version, type)
 */
const { readWantedLockfile } = require("@pnpm/lockfile-file");
const dependencyPath = require("@pnpm/dependency-path");

async function parse(directory) {
  const lockfile = await readWantedLockfile(directory, {
    ignoreIncompatible: true
  });

  specifiers = Object.values(lockfile.importers["."].specifiers);

  return Object.entries(lockfile.packages ?? {})
    .map(([depPath, pkgSnapshot]) => nameVerDevFromPkgSnapshot(depPath, pkgSnapshot))
    .filter(info => !aliasedDependency(info, specifiers))
}

function nameVerDevFromPkgSnapshot(depPath, pkgSnapshot) {
  if (!pkgSnapshot.name) {
    const pkgInfo = dependencyPath.parse(depPath)
    return {
      name: pkgInfo.name,
      version: pkgInfo.version,
      dev: pkgSnapshot.dev
    }
  }
  return {
    name: pkgSnapshot.name,
    version: pkgSnapshot.version,
    dev: pkgSnapshot.dev
  }
}

function aliasedDependency(info, specifiers) {
  const aliased = (specifier) => specifier.startsWith(`npm:${info.name}@`) || specifier == `npm:${info.name}`;

  return specifiers.some(aliased);
}

module.exports = { parse };
