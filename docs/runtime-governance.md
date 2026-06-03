# Runtime governance

This deployment repository owns the final composition of platform runtime surfaces. Service repositories own their implementations.

## Event Topology

`event-topology.json` separates event channels by consumption semantics:

- `nats_jetstream`: replayable, at-least-once, explicit ack, idempotency required.
- `nats_core`: best-effort notifications without replay or durable consumer ownership.

Every durable consumer must declare an owner repository, source file, durable name and consumed events. If the durable is declared by an owner-local command catalog instead of `common-lib/eventcatalog`, the consumer must also declare `catalog_file`. Every transactional outbox must declare its owner repository, table, worker and published events.

## Dashboard Modules

`dashboard-catalog.json` is the final dashboard composition source. Each enabled module must declare:

- owner repository and source webui directory
- service-owned `sourceManifest`
- module federation entrypoint
- API prefix and required services
- navigation key, section, icon and order

`webui` remains the shell/module host and must not become the owner of business modules.

## Runtime Adapters

`runtime-adapter-catalog.json` records provider/runtime adapter domains. Domains marked `spi` already have a registry/SPI boundary.

New migration debt is rejected by default. `event-topology.json` `migration_debt` entries and runtime adapter domains marked `legacy_inline_registry` require `ALLOW_MIGRATION_DEBT=1`, which is only for an explicit debt migration window. Normal validation and release checks must run without that variable.
