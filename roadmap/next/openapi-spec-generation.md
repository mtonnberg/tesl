# OpenAPI Specification Generation

Automatically generate an OpenAPI 3.x spec from `api` and `server` declarations.

## Value

- Zero-effort API documentation.
- Integration with Swagger UI, Redoc, Postman, etc.
- Type-safe client generation for TypeScript, Python, Go, etc.
- All Tesl-apis have a /api-docs endpoint automatically (will be updated on every build/run)

## Design

The compiler already has full knowledge of every endpoint:
- HTTP method and path
- Path captures (with types)
- Request body type (with JSON schema derivable from the record/ADT)
- Response type (with JSON schema)
- Auth mechanism

A `tesl generate-openapi MyServer --output openapi.json` command would emit the spec. The spec should be created on every "tesl run" and "tesl compile" etc if not a "--skip-openapi-generation" is provided. The documentaiton should be accessible at a /api-docs endpoint.

## Challenges

- Proof annotations don't map directly to JSON Schema (they can only be noted as descriptions).
- Existential return types need a stable JSON representation.
- Authentication mechanism mapping (session cookies → `securitySchemes`).

## Scope

Medium. The compiler already has all the data; it's mainly a question of writing the emitter.

Move to `completed/` when: the generated spec validates against the OpenAPI 3.x spec and can drive Swagger UI.

## Notes

We already have a IR-layer that the Elm- and Zod-client generators use, the openAPI generation should use the same IR layer.
