# React Coding Style

Apply when editing a React or React + TypeScript codebase.

## File layout
- Component structure is `/{routepage}/{component_name}/page.tsx` and `/{routepage}/{component_name}/styledComponents.ts`.
- Component-local types go in `/{routepage}/{component_name}/types.ts`.
- Component-local hooks go in `/{routepage}/{component_name}/use{ComponentName}.ts`.
- Tests sit next to the component as `/{routepage}/{component_name}/page.test.tsx`.
- Shared, cross-route pieces go in `/components/{component_name}/` with the same file set.
- Folder names are lower snake_case, exported component names are PascalCase.

## Components
- One exported component per `page.tsx`, default export, props typed with an explicit `Props` type.
- Function components only, no class components.
- Keep data fetching and business logic in the hook file, keep `page.tsx` to markup and wiring.
- No inline `style` props and no CSS class strings, all styling lives in `styledComponents.ts`.
- Derive state, do not duplicate it. No `useEffect` that only mirrors one state value into another.

## Text and i18n
- No user-facing string literals in components, hooks, or styled components.
- Every label, message, placeholder, and error text is added to `src/I18n/index.ts`, creating that file if it does not exist.
- Components read text through the i18n keys only, never by duplicating the string.

## Styling
- `styledComponents.ts` exports named styled components, prefixed by role, for example `Wrapper`, `Header`, `ItemRow`.
- Read colors, spacing, and typography from the theme, never hardcode hex values.

## TypeScript
- No `any`. Use `unknown` plus a narrowing check when the shape is not known.
- Prefer `type` for props and unions, `interface` only when declaration merging is needed.

## Tests
- Test behavior through React Testing Library queries by role or label, not by test id or internal state.
- Every new component ships with at least one render test and one interaction test.
