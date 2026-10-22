# Changelog

## 0.1.0 (unreleased)

First release.

- Reads Word 97-2003 `.doc` and Word 2007+ `.docx` files and prints Markdown: paragraphs, headings with their numbers, nested bullet and numbered lists with the numbers Word shows, and tables as pipe tables.
- Reads headers, footers, footnotes, endnotes and text boxes. Tracked changes read as accepted, field codes are left out, and Insert Symbol characters come out as the real characters.
- `readword` command for one or more files or standard input, with `--max-characters`.
- Refuses password-protected files, Word 6 and 95 files, and files that are not Word documents, each with its own reason.
- Size limits and loop guards for files it does not trust.
