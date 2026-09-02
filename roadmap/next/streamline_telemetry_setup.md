## Telemetry setup

## Background

Today we have the
```tesl
let _ = initTelemetry service "chat-backend" endpoint "in-memory" console True
```
syntax to configure telemetry in the main function, all special syntax. However, the mainfunction returns an App which configures "everything else". So we should change the special imperative syntax to a declarative record in the App type.

## Goals

- Make the telemetry follow the normal pattern and just be a Type "TelemetryConfig", that way the user can get help from the normal type system
- The new TelemetryConfig is a part of the App type as a telemetry-field
- We can remove all the special handling of the initTelemetry, service, endpoint console etc keywords