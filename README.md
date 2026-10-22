# readword

Turn Word documents into Markdown, in plain Ruby. It reads both formats, Word 97-2003 `.doc` and Word 2007+ `.docx`, without LibreOffice, Java or antiword. It was built for feeding Word files to LLMs and coding agents, and it is careful with files it does not trust.

```console
$ gem install readword
$ readword structured_report.doc
# Migration test report

# 1 Scope

Substances tested:

- Bisphenol A
  - food simulant A
- Toluene

# 2 Method

## 2.1 Conditions

1. Prepare the sample
   - a) at 40 C
   - b) for 10 days
2. Measure

## 2.2 Results

| Substance | Result (ug/kg) |
| --- | --- |
| Benzene | 10 |
| Steps | 1. Fill 1. Seal |

End of report.
```

## What it keeps

- Headings as `#` lines, with the numbers Word puts in front of them (`## 2.1 Scope`). Headings come from Word's heading styles, from outline levels, and from styles based on them, in any language.
- Bullet and numbered lists with their nesting and the numbers Word shows: `1.`, `a)`, `iv.`, `1.2.3`, custom labels, restarted and continued lists.
- Tables as Markdown pipe tables, one line per row. Merged cells keep their columns, and lists inside a cell stay in that cell.
- Headers, footers, footnotes, endnotes and text boxes.
- Tracked changes as if accepted: inserted text stays and deleted text goes.
- Field results, such as page numbers, dates and merge fields. Field codes are left out.
- Characters added with Insert Symbol, such as µ, ±, ≤ and °, as the real characters.
- Bold, italics and links, as `**bold**`, `*italic*` and `[text](https://example.com)`. Only links to web pages and email addresses are kept. Headings, and header cells that are bold as a whole, stay plain.

It does not keep underlining, colors, images, charts, comments in `.docx` files, or embedded objects (an Excel table pasted into the document as an object, for example).

## Use it with a coding agent

Install the gem, then add a line like this to your `CLAUDE.md` or `AGENTS.md`:

```markdown
To read a Word file (.doc or .docx), run `readword path/to/file` and read the Markdown it prints.
```

## Command line

```console
$ readword [--max-characters N] [--max-size MB] FILE...
```

- With several files, each one starts with a `==> path <==` line.
- Use `-` as the file name to read from standard input.
- If a file cannot be read, the reason goes to standard error and the exit code is 1. The other files are still printed.
- `--max-characters N` refuses documents longer than N characters, which is useful to stay inside a model's context window.
- `--max-size MB` sets the size limit described under [Safe on untrusted files](#safe-on-untrusted-files). The default is 32, and 0 turns the limit off.

## Use it from Ruby

```ruby
require 'readword'

Readword.convert_file('report.doc')                      # => "# Test report\n\n..."
Readword.convert(File.binread('report.docx'), max_characters: 150_000)
Readword.convert_file('manual.docx', max_size: 100)      # a size limit of 100 MB instead of 32
```

`convert` takes the file's bytes and works out the format from them, so a `.docx` saved with a `.doc` name still reads. Files that cannot be read raise `Readword::Error`. Its `reason` is one of:

| Reason | When |
| --- | --- |
| `:unreadable` | Not a Word document (RTF or plain text named `.doc`, for example), or damaged |
| `:no_text` | The document has no text, only images for example |
| `:too_long` | Over `max_characters`, or over the size limit (`max_size`) |
| `:password_protected` | Encrypted with a password |
| `:old_format` | Saved by Word 6 or Word 95 |

## Safe on untrusted files

- The `.doc` reader is plain Ruby, so a crafted file cannot cause the memory errors that C readers are prone to. The `.docx` reader uses Nokogiri and rubyzip.
- A size limit on the unpacked XML, its elements, the text and the formatting, so a small zip bomb or a crafted file cannot make it use gigabytes of memory. It is 32 MB by default, which reads a 300-page report. Dense documents count as bigger, since the limit also counts XML elements. At the default, the worst file we could craft, an 11 KB zip holding 1.28 million empty paragraphs, takes about 10 seconds and 330 MB of memory. Lower `max_size` for tighter bounds, or raise it for bigger documents.
- XML parts that declare their own entities are refused, which stops entity bombs.
- Links are kept only when they point to a web page or an email address, so a document cannot put a `javascript:` link into the Markdown.
- Loop guards in the `.doc` container reader, so a crafted sector chain cannot make it run forever.
- Fuzzed with 3,000,000 broken copies of real Word files, 300,000 more after headings and lists were added, and 50,000 more after bold, italics and links, with no crash and no hang.

## How it was checked

readword was compared with Apache Tika, LibreOffice and macOS textutil on 650 Word files from the Apache POI and LibreOffice test suites, and with other tools that read Word files.

### Compared with anydoc

[anydoc](https://github.com/firecrawl/anydoc) is Firecrawl's open-source converter, written in Rust. It reads many formats and also runs as an MCP server. Version 0.2.4 was run on the same 650 files. The counts below are for the 300 `.doc` and 212 `.docx` files where both Tika and textutil found text.

| | anydoc 0.2.4 | readword 0.2 |
| --- | --- | --- |
| `.doc` files read | 260 | 281 |
| `.doc` files missing words that both Tika and textutil found | 122 | 29, of which 13 are Word 6 or 95 files that neither tool reads |
| Text left out of `.doc` files | page headers and footers, comments, some text boxes | field codes, embedded objects |
| `.doc` files saved by macOS TextEdit | refused | read |
| `.docx` files read | 208 | 210 |
| `.docx` files missing words that both Tika and textutil found | 9, for example content controls in tables and deeply nested tables | 2: an entity test file refused on purpose, and a link that splits a name from its footnote number |
| List numbers | ordinal styles shown as plain numbers, some continued and restarted lists numbered differently | match LibreOffice |
| Lists inside table cells | numbers dropped | numbers kept |
| Bold, italics and links | kept | kept |
| Other formats | PDF, PowerPoint, Excel, OpenDocument, RTF, EPUB, CSV and more | none |
| Median time per file | 0.2 ms | 0.5 ms |
| 10,000 crafted `.doc` files | no crash or hang | no crash or hang |
| Use from | Rust, Node, Python, WebAssembly, command line, MCP | Ruby, command line |

For Word files, readword keeps more of the text and the list numbers Word shows. anydoc is the better pick for other formats or when speed matters most.

### Compared with antiword and the docx gem

| | antiword 0.37 | docx gem 0.13 | readword 0.1 |
| --- | --- | --- | --- |
| Reads `.doc` | yes | no | yes |
| Reads `.docx` | no | yes | yes |
| Files missing words that both Tika and textutil found | 84 of 246 `.doc` files | 60 of 207 `.docx` files | 8 `.doc` files, no `.docx` files |
| Headers and footers | not printed | | read |
| Tables | long or two-paragraph cells spill into fake rows | paragraphs and tables come back as separate lists, so their order is lost | one line per row, in reading order |
| Track Changes | deleted text kept | inserted text dropped | deleted text left out, inserted text kept |
| 10,000 crafted `.doc` files | 164 crashes and 387 memory errors | | no crashes |
| A 1 MB zip that unpacks to 1 GB | | 3.2 GB of memory used | refused in 0.17 s |
| Install | system package (no Homebrew formula) | gem | gem |

This comparison was made earlier, with readword 0.1 and a smaller set of the test files. The words readword misses are field codes, embedded objects, charts and picture names.

List numbers were compared with LibreOffice's on the 45 test files that have numbered lists. All numbers match in 41 of them. Of the other four, two are deliberately corrupted fuzz files, one changed its numbering with Track Changes, and one numbers an empty paragraph that holds a section break, where LibreOffice drops the paragraph.

## Development

```console
$ bundle install
$ bundle exec rake    # tests and RuboCop
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).
