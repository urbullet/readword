# Changelog

## 0.2.0 (2026-10-22)

- Keeps bold, italics and links, as `**bold**`, `*italic*` and `[text](url)`. Only links to web pages and email addresses are kept. Headings, and header cells that are bold as a whole, stay plain.
- The size limit is now an option: `max_size:` in Ruby and `--max-size` on the command line, in megabytes. The default went up from 10 to 32, which reads a 300-page report, and 0 turns the limit off.

## 0.1.1 (2026-10-22)

Same code as 0.1.0. Only the author name in the gem's details changed.

## 0.1.0 (2026-10-22)

First release.

- Reads Word 97-2003 `.doc` and Word 2007+ `.docx` files and prints Markdown: paragraphs, headings with their numbers, nested bullet and numbered lists with the numbers Word shows, and tables as pipe tables.
- Reads headers, footers, footnotes, endnotes and text boxes. Tracked changes read as accepted, field codes are left out, and Insert Symbol characters come out as the real characters.
- `readword` command for one or more files or standard input, with `--max-characters`.
- Refuses password-protected files, Word 6 and 95 files, and files that are not Word documents, each with its own reason.
- Size limits and loop guards for files it does not trust.
