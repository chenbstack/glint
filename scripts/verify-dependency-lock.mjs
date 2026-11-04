import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Keep the generated Xcode project, XcodeGen source and checked-in resolution
// aligned. Real resolution must fail rather than silently change this pin.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
/** Read project text; relative is its repository path; returns UTF-8 contents. */
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const lock = JSON.parse(read('Glint.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'));
assert.equal(lock.pins.length, 1);
const pin = lock.pins[0];
assert.equal(pin.identity, 'sparkle');
assert.equal(pin.kind, 'remoteSourceControl');
assert.equal(pin.location, 'https://github.com/sparkle-project/Sparkle.git');
assert.equal(pin.state.version, '2.6.4');
assert.equal(pin.state.revision, '0ef1ee0220239b3776f433314515fd849025673f');
assert.match(read('project.yml'), /Sparkle:\s+url: https:\/\/github.com\/sparkle-project\/Sparkle.git\s+exactVersion: "2\.6\.4"/);
assert.match(read('Glint.xcodeproj/project.pbxproj'), /kind = exactVersion;\s+version = 2\.6\.4;/);
for (const workflow of ['ci.yml', 'release.yml']) {
  const content = read(`.github/workflows/${workflow}`);
  for (const command of content.split(/\bxcodebuild \\\n/).slice(1)) {
    const args = command.split(/\n\s*\n/)[0];
    assert.match(args, /-disableAutomaticPackageResolution/);
    assert.match(args, /-onlyUsePackageVersionsFromResolvedFile/);
  }
}
console.log('PASS: Sparkle exact declarations, real tag revision and CI/release lock enforcement agree');
