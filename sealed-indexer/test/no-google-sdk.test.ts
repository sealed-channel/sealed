/**
 * CI grep guard — ensures no Google/Firebase SDK dependencies leak into the codebase.
 *
 * Task 3.1 privacy requirement: the indexer must not import firebase-admin,
 * @google-cloud/*, or reference Firebase SDK symbols. This test recursively
 * scans src/ and fails the build if forbidden imports are detected.
 */

import * as fs from 'fs';
import * as path from 'path';

describe('Google SDK Import Guard', () => {
  const srcDir = path.join(__dirname, '../src');

  // Forbidden import patterns
  const forbiddenImports = [
    /import.*['"`]firebase-admin['"`]/,
    /require\(['"`]firebase-admin['"`]\)/,
    /import.*['"`]@google-cloud\/.*['"`]/,
    /require\(['"`]@google-cloud\/.*['"`]\)/,
  ];

  // Forbidden Firebase SDK symbols (imports without quotes)
  const forbiddenSymbols = [
    /\bFirebaseApp\b/,
    /\bgetMessaging\b/,
    /admin\.messaging\(\)/,
    /firebase\.messaging\(\)/,
  ];

  function getAllTsFiles(dir: string): string[] {
    const files: string[] = [];

    function walk(currentDir: string) {
      const entries = fs.readdirSync(currentDir, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = path.join(currentDir, entry.name);

        if (entry.isDirectory()) {
          walk(fullPath);
        } else if (entry.isFile() && entry.name.endsWith('.ts')) {
          files.push(fullPath);
        }
      }
    }

    walk(dir);
    return files;
  }

  it('should not import firebase-admin or @google-cloud packages', () => {
    const tsFiles = getAllTsFiles(srcDir);
    expect(tsFiles.length).toBeGreaterThan(0); // Sanity check

    const violations: { file: string; line: number; content: string }[] = [];

    for (const filePath of tsFiles) {
      const content = fs.readFileSync(filePath, 'utf8');
      const lines = content.split('\n');

      lines.forEach((line, index) => {
        // Check for forbidden imports
        for (const pattern of forbiddenImports) {
          if (pattern.test(line)) {
            violations.push({
              file: path.relative(srcDir, filePath),
              line: index + 1,
              content: line.trim()
            });
          }
        }

        // Check for forbidden symbols
        for (const pattern of forbiddenSymbols) {
          if (pattern.test(line)) {
            violations.push({
              file: path.relative(srcDir, filePath),
              line: index + 1,
              content: line.trim()
            });
          }
        }
      });
    }

    if (violations.length > 0) {
      const errorMsg = violations
        .map(v => `${v.file}:${v.line} - ${v.content}`)
        .join('\n');

      fail(`Forbidden Google SDK imports detected:\n${errorMsg}`);
    }
  });

  it('should scan at least the expected source files', () => {
    const tsFiles = getAllTsFiles(srcDir);
    const fileNames = tsFiles.map(f => path.basename(f));

    // Verify we're scanning key files that should exist
    expect(fileNames).toContain('ohttp-apns.ts');
    expect(fileNames).toContain('unifiedpush-dispatcher.ts');
    expect(fileNames).toContain('push-sender.ts'); // Legacy but still present
  });
});