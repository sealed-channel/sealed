import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['src/__tests__/**/*.test.ts'],
    testTimeout: 60_000,
    hookTimeout: 60_000,
    passWithNoTests: true,
    // Integration tests share LocalNet dispenser + deterministic LogicSig
    // escrow address; serialize file execution to avoid txn-pool / box races.
    fileParallelism: false,
  },
});
