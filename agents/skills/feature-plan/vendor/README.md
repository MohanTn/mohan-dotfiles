# Vendored: mermaid.js

`mermaid.min.js` — v11.16.0, UMD build, unmodified, from `npm pack mermaid@11` (`package/dist/mermaid.min.js`). MIT licensed (license banner kept at the end of the file).

Embedded inline (via the `{{MERMAID_BUNDLE_JS}}` marker, see `featurePlan-inject.js`) into every generated `featurePlan-<slug>.html` so the "Design & Architecture" diagram renders fully offline, no CDN, no network call. Sets `window.mermaid` as a plain classic `<script>` (no `type="module"` needed).

To update: `npm pack mermaid@<version>`, extract `package/dist/mermaid.min.js`, overwrite this file, bump the version in this note.
