# Contributing to OpenGreenIoT Mobile

Thank you for your interest in contributing! We welcome contributions from everyone.

## How to Contribute

1. **Fork** the repository
2. **Create a branch** for your feature or fix: `git checkout -b feature/my-feature`
3. **Write tests** for your changes
4. **Run tests** to make sure everything passes: `flutter test` and `cd rust && cargo test`
5. **Run the linter**: `flutter analyze` and `cd rust && cargo clippy --all-targets --all-features -- -D warnings`
6. **Format your code**: `dart format .` and `cd rust && cargo fmt --all`
7. **Commit** your changes with a clear message
8. **Push** to your fork and **open a Pull Request**

## Development Setup

### Flutter

```bash
flutter pub get
flutter test
```

### Rust

Install the stable Rust toolchain (see [README — Prerequisites](README.md#prerequisites)), then:

```bash
cd rust
cargo test
cargo clippy --all-targets --all-features -- -D warnings
cargo fmt --all
```

Before opening a PR, run the local CI mirror (covers both Flutter and Rust):

```bash
./scripts/test.sh
```

## Code Style

- Follow the [Effective Dart](https://dart.dev/effective-dart) guidelines
- Use `dart format` to format code
- Keep lines under 80 characters where reasonable
- Write descriptive variable and function names
- Rust: run `cargo fmt` and keep `cargo clippy -- -D warnings` clean; follow standard Rust naming (snake_case items, CamelCase types)

## Reporting Issues

- Use the [issue templates](.github/ISSUE_TEMPLATE/) provided
- Include steps to reproduce bugs
- Include device/OS information for BLE-related issues

## License

By contributing, you agree that your contributions will be licensed under the
Apache License 2.0.
