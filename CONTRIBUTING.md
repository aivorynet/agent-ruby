# Contributing to AIVory Monitor Ruby Agent

Thank you for your interest in contributing to the AIVory Monitor Ruby Agent. Contributions of all kinds are welcome -- bug reports, feature requests, documentation improvements, and code changes.

## How to Contribute

- **Bug reports**: Open an issue at [GitHub Issues](https://github.com/aivorynet/agent-ruby/issues) with a clear description, steps to reproduce, and your environment details (Ruby version, OS, framework).
- **Feature requests**: Open an issue describing the use case and proposed behavior.
- **Pull requests**: See the Pull Request Process below.

## Development Setup

### Prerequisites

- Ruby 3.0 or later
- Bundler

### Build and Test

```bash
cd monitor-agents/agent-ruby
bundle install
bundle exec rspec
```

### Running the Agent

Add the gem to your `Gemfile` and call the initialization method at application startup. See the README for integration details.

## Coding Standards

- Follow the existing code style in the repository.
- Write tests for all new features and bug fixes.
- Follow the [Ruby Style Guide](https://rubystyle.guide/).
- Keep TracePoint and exception hook usage well-documented.
- Ensure compatibility with Ruby 3.0+.

## Pull Request Process

1. Fork the repository and create a feature branch from `main`.
2. Make your changes and write tests.
3. Ensure all tests pass (`bundle exec rspec`).
4. Submit a pull request on [GitHub](https://github.com/aivorynet/agent-ruby) or GitLab.
5. All pull requests require at least one review before merge.

## Reporting Bugs

Use [GitHub Issues](https://github.com/aivorynet/agent-ruby/issues). Include:

- Ruby version (`ruby --version`) and OS
- Agent version
- Framework (Rails, Sinatra, etc.) if applicable
- Error output or stack traces
- Minimal reproduction steps

## Security

Do not open public issues for security vulnerabilities. Report them to **security@aivory.net**. See [SECURITY.md](SECURITY.md) for details.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
