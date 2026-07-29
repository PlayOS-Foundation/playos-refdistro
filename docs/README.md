# Documentation

This directory documents the Alpine-based PlayOS reference distribution. Platform
behavior is specified in `playos-spec`; this repository documents how the
reference OS is built, configured, and validated.

## Start here

| Need | Document |
|---|---|
| Build an image on Ubuntu | [Build on Ubuntu](build/ubuntu.md) |
| Understand image creation and contents | [Image pipeline](architecture/image-pipeline.md) |
| Understand boot and service policy | [Boot and services](architecture/boot-and-services.md) |
| Validate an artifact or device | [Validation](validation.md) |
| Work on the ROG Ally reference device | [ROG Ally](hardware/rog-ally.md) |
| Track and resolve known issues | [Audit Findings](audit-findings.md) |

## Documentation rules

- Keep one canonical document for each concern listed above.
- Describe current script behavior accurately; label planned behavior as planned.
- Put platform contracts in `playos-spec`, not here.
- Update the relevant canonical document whenever image configuration, service
  order, build flow, or validation requirements change.
