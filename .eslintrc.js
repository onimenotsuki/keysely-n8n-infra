module.exports = {
  parser: '@typescript-eslint/parser',
  parserOptions: {
    ecmaVersion: 2022,
    sourceType: 'module',
    project: './tsconfig.json',
  },
  extends: ['airbnb-base', 'airbnb-typescript/base', 'prettier'],
  plugins: ['@typescript-eslint', 'import'],
  env: {
    node: true,
    es2022: true,
    jest: true,
  },
  rules: {
    'import/prefer-default-export': 'off',
    'import/no-extraneous-dependencies': [
      'error',
      {
        devDependencies: ['**/*.test.ts', '**/*.spec.ts', '**/jest.config.js', '**/jest.setup.js'],
      },
    ],
    '@typescript-eslint/no-unused-vars': [
      'error',
      {
        argsIgnorePattern: '^_',
        varsIgnorePattern: '^_',
        caughtErrorsIgnorePattern: '^_',
      },
    ],
    'no-underscore-dangle': ['error', { allow: ['_stack', '_unused'] }],
    '@typescript-eslint/naming-convention': [
      'error',
      {
        selector: 'variable',
        format: ['camelCase', 'PascalCase', 'UPPER_CASE'],
        filter: {
          regex: '^_',
          match: false,
        },
      },
      {
        selector: 'variable',
        modifiers: ['unused'],
        format: null,
        filter: {
          regex: '^_',
          match: true,
        },
      },
    ],
    'no-console': ['warn', { allow: ['warn', 'error'] }],
    'class-methods-use-this': 'off',
    'no-new': 'off', // CDK uses 'new' for side effects (resource creation)
  },
  ignorePatterns: [
    'node_modules/',
    'dist/',
    'cdk.out/',
    '*.js',
    '!jest.config.js',
    '!.eslintrc.js',
  ],
};
