# .NET Coding Style

Apply when editing a C# or .NET codebase.

## File layout
- Feature structure is `/Features/{Feature}/{UseCase}/{UseCase}Handler.cs`, `{UseCase}Request.cs`, `{UseCase}Response.cs`, `{UseCase}Validator.cs`.
- Endpoints live in `/Features/{Feature}/{Feature}Controller.cs`, one controller per feature.
- Data access lives in `/Infrastructure/Repositories/{Entity}Repository.cs` behind an `I{Entity}Repository` interface.
- Domain models live in `/Domain/{Feature}/{Entity}.cs`, free of EF and ASP.NET attributes.
- Mapping lives in `/Features/{Feature}/{UseCase}/{UseCase}Mapper.cs`.
- One public type per file, file name matches the type name.

## Structure
- Controllers only validate, delegate to a handler, and translate the result to a status code. No business logic.
- Handlers own the business logic and depend on interfaces, never on concrete infrastructure types.
- Constructor injection only, dependencies stored in `private readonly` fields.
- Requests and responses are their own DTO types, never expose domain entities over the wire.

## Language rules
- Nullable reference types enabled, no `!` null-forgiving operator to silence a warning.
- `async` all the way, every async method takes and passes a `CancellationToken`, no `.Result` or `.Wait()`.
- Prefer records for DTOs, classes for entities and services.
- Throw domain-specific exceptions, catch only what you can handle.
- `var` when the type is obvious from the right hand side, explicit type otherwise.

## Tests
- Tests mirror the source path under `/Tests/Features/{Feature}/{UseCase}HandlerTests.cs`.
- Arrange, Act, Assert, one behavior per test, mock only the interfaces the handler depends on.
