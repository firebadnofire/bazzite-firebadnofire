# AGENTS.md

This repository builds `bazzite-firebadnofire`, a personal Bazzite-derived Universal Blue/bootc workstation image.

This file defines standing instructions for coding agents working in this repository. Follow the user's current request first, then this file, then repository documentation and existing implementation conventions.

## Read Before Editing

Before making substantive changes:

1. Read `README.md`.
2. Read `VISION.md` if present.
3. Read the project dossier or other repository handoff documentation if present.
4. Inspect `git status --short --branch`.
5. Inspect relevant recent Git history when it may affect the requested work.
6. Inspect the actual files and direct consumers involved in the change.
7. Do not assume a previous dossier, prompt, or handoff still exactly describes the working tree.

Preserve unrelated user changes.

## Documentation Contract

`README.md` is the primary documentation entrypoint for this project.

Keep it useful to a human operator who has cloned the repository and needs to understand, build, operate, recover, or maintain `bazzite-firebadnofire`.

When a change affects how the project is configured, built, tested, published, installed, updated, verified, or recovered, update the README as part of the same change.

Do not leave essential operator knowledge only in:

* workflow YAML;
* shell scripts;
* comments;
* commit messages;
* agent handoff notes;
* `AGENTS.md`;
* external chat conversations.

The README should point to specialized documentation when a subject becomes too detailed for the main document, but the README must remain the discoverable starting point.

Avoid documenting hypothetical behavior as though it is implemented. Documentation must distinguish current functionality from planned functionality.

## Operator Procedures

The README must document enough information for an operator to reproduce and operate the project's build and release process without needing prior chat context.

In particular, keep documentation current for:

### CI prerequisites

Document:

* which CI platform is expected;
* required runner capabilities;
* container/DinD requirements;
* required build tools or privileged capabilities;
* registry requirements;
* architecture assumptions;
* any relevant storage or resource requirements.

### Secrets and external configuration

Document every required CI secret and externally configured value by name and purpose.

For each secret or external value, explain:

* what it is used for;
* where the operator is expected to configure it;
* whether it is required for builds, publication, signing, disk artifacts, or another stage;
* how the operator can obtain or generate it when that can be safely documented;
* whether it contains sensitive material.

Never include the actual secret value.

Never commit:

* private signing keys;
* registry credentials;
* access tokens;
* passwords;
* S3 credentials;
* machine credentials;
* other sensitive material.

Public verification keys may be committed when intentionally part of the project's verification contract.

### Starting a CI build

The README must explain exactly how an operator initiates a CI build.

Document all supported triggers that actually exist, such as:

* pushing to a particular branch;
* opening or updating a pull request;
* manually dispatching a workflow;
* scheduled builds;
* tags or releases, if applicable.

Explain what each trigger does when behavior differs.

For example, clearly distinguish:

* validation-only builds;
* image builds;
* publication;
* signing;
* disk/ISO artifact generation;
* production release behavior.

If a build requires secrets or external configuration before it can succeed, state that before the trigger instructions.

### Build outputs

Document:

* where OCI images are published;
* image naming;
* important tag conventions;
* where QCOW2/ISO artifacts appear, if supported;
* how to identify an immutable image digest;
* how signatures can be verified.

### Local validation

Keep useful local commands documented, including the relevant progression from fast checks through full image builds and VM testing.

Do not imply that a lower-fidelity validation proves a higher-fidelity result.

For example:

* syntax/lint success does not prove an OCI build;
* OCI build success does not prove successful publication;
* publication does not prove signature verification;
* `bootc container lint` does not prove graphical boot;
* VM boot does not prove compatibility with physical hardware.

### Installation, update, rollback, and recovery

When these procedures become implemented and stable, document the supported operator procedure for:

* installing or rebasing onto the image;
* updating;
* selecting image streams/tags;
* rolling back a deployment;
* recovering from a bad deployment;
* verifying the image/signature before trusting it where appropriate.

Do not invent commands merely to fill a documentation section. Document tested procedures.

## Product Direction

Use `VISION.md` as the product specification when it exists.

Do not silently redefine the project's goals because an upstream Universal Blue or Bazzite template behaves differently.

This repository should remain a reasonably shallow personal layer over upstream Bazzite. Prefer inheriting and configuring upstream functionality over copying, vendoring, or independently maintaining it.

Personal-project scope means minimal image size is not a primary objective. Reliability, reproducibility, useful workstation functionality, and maintainability matter more than removing every unnecessary package.

## Upstream Awareness

This project inherits substantial behavior from Bazzite, Universal Blue, Fedora, bootc, and related upstream projects.

Before implementing significant system behavior:

1. determine whether upstream already provides it;
2. prefer supported upstream mechanisms;
3. verify current package names and interfaces rather than guessing;
4. avoid duplicating Bazzite functionality unnecessarily;
5. avoid permanently enabling third-party repositories without a justified need.

When changing the base image, keep tags and digest pins coherent.

Treat upstream image, action, and build-tool updates as supply-chain changes requiring appropriate validation.

## Repository and Image Safety

Treat the following as privileged code:

* `Containerfile`;
* image build scripts;
* files copied into the system image;
* systemd units;
* CI workflow shell commands;
* installer configuration and `%post` scripts;
* scripts executed during image construction.

Preserve strict error handling.

Do not make failures disappear with broad `|| true`, disabled linting, weakened validation, or similar workarounds.

Do not remove `bootc container lint` merely to obtain a successful build.

Do not disable TLS or certificate verification to work around registry or network failures.

Do not weaken signing behavior merely to obtain a successful publication.

Prefer idempotent image construction.

Do not put mutable application state or user data into immutable system locations without understanding the bootc filesystem semantics involved.

## CI and Signing

CI configuration must remain understandable and auditable.

Prefer portable operations over unnecessary CI-provider-specific magic.

Production publication must sign the immutable image digest, not merely a mutable tag.

Signing should fail closed when signing is part of the publication contract.

Agents may write workflow references to secrets, but must never fabricate, print, recover, expose, or commit secret values.

If an external setting must be provisioned manually, implement everything that can safely be implemented in the repository and document the remaining operator action in the README.

## Validation

Use the smallest relevant validation first and increase fidelity as appropriate.

Typical progression:

1. inspect the diff;
2. run repository checks;
3. lint/format affected shell code;
4. validate workflow/YAML/TOML syntax;
5. build the OCI image;
6. run `bootc container lint`;
7. inspect installed packages and system files;
8. rechunk when relevant;
9. boot a VM when relevant and available;
10. test publication/signing when explicitly authorized and credentials are available;
11. test update/rebase/rollback behavior when relevant and safe.

Changes affecting graphics, kernel behavior, drivers, networking, systemd, virtualization, boot, or desktop sessions deserve boot-level testing when practical.

Do not report a validation step as completed unless it actually ran successfully.

At handoff, distinguish:

* statically inspected;
* locally executed;
* built;
* booted;
* published;
* signature-verified;
* physical-hardware-tested.

## Autonomous Decisions

Agents are expected to make ordinary engineering decisions without repeatedly asking the operator.

Investigate and choose reasonable implementations for:

* Fedora package names;
* package grouping;
* shell implementation details;
* maintainable repository organization;
* appropriate validation commands;
* straightforward Hyprland desktop plumbing;
* documentation structure;
* CI implementation details consistent with documented infrastructure.

Prefer primary upstream documentation when research is necessary.

Ask the operator instead of guessing when work requires:

* a private credential or secret;
* an unknown external account or registry value;
* destructive changes outside the repository/build environment;
* modification of physical workstation state;
* production publication that has not been authorized;
* machine-specific VFIO configuration;
* a genuinely unresolved product decision with materially different outcomes.

## Change Discipline

Make the smallest coherent change that satisfies the requested goal.

Do not turn a focused task into unrelated repository cleanup.

However, when a requested change crosses an established configuration contract, update all directly connected consumers together rather than knowingly leaving the repository internally inconsistent.

Match existing project conventions unless there is a concrete reason to improve them.

Keep generated files, build outputs, credentials, and unrelated formatting out of commits.

Before handoff:

1. run `git diff --check`;
2. inspect the complete diff;
3. run all relevant validation available in the environment;
4. search for stale names/references when identity or paths changed;
5. update README operator documentation affected by the change;
6. report unresolved risks and external requirements.

## Definition of Done

A change is not complete merely because the implementation exists.

For operator-affecting changes, completion includes accurate README documentation.

For CI changes, completion includes documenting how the operator provisions required external values and how the CI process is started.

For publication/signing changes, completion includes documenting the registry destination, image identity, required secrets, tag/digest behavior, and verification procedure where implemented.

For system-image changes, completion includes the strongest practical validation available and an honest statement of what remains untested.

Leave the repository in a state where the next human or agent can understand how the system works without reconstructing essential procedures from Git history or chat logs.
