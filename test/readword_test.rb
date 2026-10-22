# frozen_string_literal: true

require 'test_helper'

class ReadwordTest < Minitest::Test
  include WordDocumentHelper

  NAMESPACES = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ' \
               'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" ' \
               'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" ' \
               'xmlns:v="urn:schemas-microsoft-com:vml"'
  RELATIONSHIPS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

  test 'a .docx results table becomes one line per row, keeping empty and merged cells in their columns' do
    body = paragraph('Test Report No. 2026/0815') +
           table(row(cell(paragraph('Substance')), cell(paragraph('Result (µg/kg)'), span: 2)),
                 row(cell(paragraph('Bisphenol A')), cell(paragraph('&lt;5')), cell(paragraph('5'))),
                 row(cell(paragraph('Benzene')), cell('<w:p/>'), cell(paragraph('10'))))

    assert_equal <<~TEXT.chomp, Readword.convert(docx(body))
      Test Report No. 2026/0815

      | Substance | Result (µg/kg) |  |
      | --- | --- | --- |
      | Bisphenol A | <5 | 5 |
      | Benzene |  | 10 |
    TEXT
  end

  test 'paragraphs inside a .docx cell share its line, and a cell holding a table keeps the inner rows' do
    inner = table(row(cell(paragraph('Toluene')), cell(paragraph('120'))))
    body = table(row(cell(paragraph('Bisphenol A') + paragraph('(BPA)')), cell(paragraph('80-05-7'))),
                 row(cell(paragraph('Volatiles') + inner)))

    assert_equal <<~TEXT.chomp, Readword.convert(docx(body))
      | Bisphenol A (BPA) | 80-05-7 |
      | --- | --- |

      Volatiles

      | Toluene | 120 |
      | --- | --- |
    TEXT
  end

  test 'a table wrapped in a content control, custom XML or alternate content in a .docx cell keeps its own rows' do
    inner = table(row(cell(paragraph('Toluene')), cell(paragraph('120'))))
    wrappers = [
      "<w:sdt><w:sdtPr/><w:sdtContent>#{inner}</w:sdtContent></w:sdt>",
      "<w:customXml w:element=\"results\">#{inner}</w:customXml>",
      "<mc:AlternateContent><mc:Choice Requires=\"wps\">#{inner}</mc:Choice><mc:Fallback>#{inner}</mc:Fallback></mc:AlternateContent>"
    ]

    wrappers.each do |wrapped|
      assert_equal "Volatiles\n\n| Toluene | 120 |\n| --- | --- |", Readword.convert(docx(table(row(cell(paragraph('Volatiles') + wrapped)))))
    end
  end

  test 'a table inside a text box in a .docx cell keeps its own rows' do
    inner = table(row(cell(paragraph('Toluene')), cell(paragraph('120'))))
    box = "<w:p><w:r><w:pict><v:textbox><w:txbxContent>#{inner}</w:txbxContent></v:textbox></w:pict></w:r></w:p>"

    text = Readword.convert(docx(table(row(cell(paragraph('Volatiles') + box)))))

    assert_equal ['Volatiles', '| Toluene | 120 |', '| --- | --- |'], text.lines(chomp: true).reject(&:empty?)
  end

  test 'a .docx cell claiming a huge column span fills at most the 63 columns a Word table can have' do
    body = table(row(cell(paragraph('x'), span: 1_000_000_000)))

    assert_equal "| #{(['x'] + ([''] * 62)).join(' | ')} |\n| #{(['---'] * 63).join(' | ')} |", Readword.convert(docx(body))
  end

  test 'a .docx with many wide cells is refused as too long once their columns pass the node budget' do
    cells = Array.new(1_000) { cell('<w:p/>', span: Readword::Docx::MAX_GRID_SPAN) }

    error = assert_raises(Readword::Error) { Readword.convert(docx(table(row(*cells))), max_size: 1) }

    assert_equal Readword::TOO_LONG, error.reason
  end

  test 'a .docx header, footer and footnotes are read along with the body' do
    parts = {
      'word/header1.xml' => "<w:hdr #{NAMESPACES}>#{paragraph('Example Lab Test Report')}</w:hdr>",
      'word/footer1.xml' => "<w:ftr #{NAMESPACES}>#{paragraph('Page 1 of 1')}</w:ftr>",
      'word/footnotes.xml' => "<w:footnotes #{NAMESPACES}>" \
                              "<w:footnote w:type=\"separator\" w:id=\"-1\">#{paragraph('-----')}</w:footnote>" \
                              "<w:footnote w:id=\"1\">#{paragraph('LOQ: limit of quantification')}</w:footnote></w:footnotes>"
    }
    relationships = %w[header header1.xml footer footer1.xml footnotes footnotes.xml].each_slice(2).map do |type, target|
      "<Relationship Id=\"#{type}\" Type=\"#{RELATIONSHIPS}/#{type}\" Target=\"#{target}\"/>"
    end

    assert_equal <<~TEXT.chomp, Readword.convert(docx(paragraph('Results'), parts: parts, relationships: relationships.join))
      Example Lab Test Report

      Results

      LOQ: limit of quantification

      Page 1 of 1
    TEXT
  end

  test 'an empty part in a .docx, such as an empty header, does not stop the rest from being read' do
    relationships = "<Relationship Id=\"header\" Type=\"#{RELATIONSHIPS}/header\" Target=\"header1.xml\"/>"

    assert_equal 'Results', Readword.convert(docx(paragraph('Results'), parts: { 'word/header1.xml' => '' }, relationships: relationships))
  end

  test 'a .docx part listed more than once, in any letter case, is read once' do
    parts = {
      'word/header1.xml' => "<w:hdr #{NAMESPACES}>#{paragraph('Example Lab Test Report')}</w:hdr>",
      'word/footnotes.xml' => "<w:footnotes #{NAMESPACES}>" \
                              "<w:footnote w:id=\"1\">#{paragraph('LOQ: limit of quantification')}</w:footnote></w:footnotes>"
    }
    targets = %w[footnotes footnotes.xml footnotes Footnotes.xml footnotes FOOTNOTES.XML header header1.xml header header1.xml]
    relationships = targets.each_slice(2).map.with_index do |(type, target), index|
      "<Relationship Id=\"rId#{index}\" Type=\"#{RELATIONSHIPS}/#{type}\" Target=\"#{target}\"/>"
    end

    assert_equal <<~TEXT.chomp, Readword.convert(docx(paragraph('Results'), parts: parts, relationships: relationships.join))
      Example Lab Test Report

      Results

      LOQ: limit of quantification
    TEXT
  end

  test 'tracked deletions and field codes are left out of a .docx while field results stay' do
    body = '<w:p><w:r><w:t xml:space="preserve">Result: </w:t></w:r><w:del><w:r><w:delText>12</w:delText></w:r></w:del>' \
           '<w:ins><w:r><w:t>15</w:t></w:r></w:ins></w:p>' \
           '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText>PAGE</w:instrText></w:r>' \
           '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>3</w:t></w:r>' \
           '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'

    assert_equal "Result: 15\n\n3", Readword.convert(docx(body))
  end

  test 'a field nested in the code of another .docx field is left out, so its result is not read twice' do
    inner = '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> DOCVARIABLE Result </w:instrText></w:r>' \
            '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>12</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>'
    result = "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText> IF </w:instrText></w:r>#{inner}" \
             "<w:r><w:instrText> = \"\" \"n.d.\" </w:instrText></w:r>#{inner}" \
             '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>12</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'

    assert_equal "| Benzene | 12 |\n| --- | --- |", Readword.convert(docx(table(row(cell(paragraph('Benzene')), cell(result)))))
  end

  test 'Symbol-font characters in a .docx come out as the real characters' do
    body = '<w:p><w:r><w:t xml:space="preserve">5 </w:t><w:sym w:font="Symbol" w:char="F06D"/><w:t xml:space="preserve">g/kg </w:t>' \
           '<w:sym w:font="Symbol" w:char="F0B1"/><w:t xml:space="preserve"> 1, </w:t><w:sym w:font="Symbol" w:char="F0A3"/>' \
           '<w:t xml:space="preserve"> LOQ</w:t></w:r></w:p>'

    assert_equal '5 µg/kg ± 1, ≤ LOQ', Readword.convert(docx(body))
  end

  test 'a .docx text box that Word stores twice for older versions is read once' do
    box = "<w:txbxContent>#{paragraph('Sample ID: S-1')}</w:txbxContent>"
    body = '<w:p><w:r><mc:AlternateContent>' \
           "<mc:Choice Requires=\"wps\"><w:drawing><wps:txbx>#{box}</wps:txbx></w:drawing></mc:Choice>" \
           "<mc:Fallback><w:pict><v:textbox>#{box}</v:textbox></w:pict></mc:Fallback>" \
           '</mc:AlternateContent></w:r></w:p>'

    assert_equal 'Sample ID: S-1', Readword.convert(docx(body))
  end

  test 'a .docx without any text is refused with a clear message' do
    error = assert_raises(Readword::Error) { Readword.convert(docx('<w:p/>')) }

    assert_equal Readword::NO_TEXT, error.reason
  end

  test 'a .docx with more text than the given limit is refused as too long' do
    error = assert_raises(Readword::Error) { Readword.convert(docx(paragraph('x' * 101)), max_characters: 100) }

    assert_equal Readword::TOO_LONG, error.reason
  end

  test 'a .docx part bigger than the limit is refused as too long without reading all of it' do
    bytes = zip_with('word/document.xml' => ' ' * (Readword::MEGABYTE + 1))

    error = assert_raises(Readword::Error) { Readword.convert(bytes, max_size: 1) }

    assert_equal Readword::TOO_LONG, error.reason
  end

  test 'a .docx whose parts each fit the limit but together do not is refused as too long' do
    padding = ' ' * (Readword::MEGABYTE / 2)
    parts = { 'word/header1.xml' => "<w:hdr #{NAMESPACES}>#{paragraph('Example Lab Test Report')}#{padding}</w:hdr>" }
    relationships = "<Relationship Id=\"rId1\" Type=\"#{RELATIONSHIPS}/header\" Target=\"header1.xml\"/>"
    bytes = docx(paragraph('Results') + padding, parts: parts, relationships: relationships)

    error = assert_raises(Readword::Error) { Readword.convert(bytes, max_size: 1) }

    assert_equal Readword::TOO_LONG, error.reason
  end

  test 'a .docx with more XML nodes than the reader takes, attributes included, is refused as too long' do
    body = '<w:p w:x="1"/>' * ((Readword::Docx::NODES_PER_MEGABYTE / 2) + 1)

    error = assert_raises(Readword::Error) { Readword.convert(docx(body), max_size: 1) }

    assert_equal Readword::TOO_LONG, error.reason
  end

  test 'a .docx part that declares its own entities is refused as unreadable, so an entity bomb cannot stall the reader' do
    entities = (1..3).map { |level| %(<!ENTITY e#{level} "#{"&e#{level - 1};" * 10}">) }.join
    part = %(<!DOCTYPE w:document [<!ENTITY e0 "lol">#{entities}]><w:document #{NAMESPACES}><w:body>#{paragraph('&e3;')}</w:body></w:document>)

    error = assert_raises(Readword::Error) { Readword.convert(zip_with('word/document.xml' => part)) }

    assert_equal Readword::UNREADABLE, error.reason
  end

  test 'a file that is not really a .docx is refused as unreadable' do
    error = assert_raises(Readword::Error) { Readword.convert('not a zip file') }

    assert_equal Readword::UNREADABLE, error.reason
  end

  test 'a .doc report keeps its paragraphs, table rows, empty cells and special characters' do
    assert_equal <<~TEXT.chomp, Readword.convert(lims_report_doc)
      Test Report No. 2026/0815

      Customer reference: ABC-123

      Simulant: Ethanol 10% (v/v), 10 days at 40 °C

      | Substance | CAS No. | Result (µg/kg) | LOQ (µg/kg) |
      | --- | --- | --- | --- |
      | Bisphenol A (BPA) | 80-05-7 | <5 | 5 |
      | Benzene |  | n.d. | 10 |
      | Toluene | 108-88-3 | 120 ± 15 |  |

      Results ≤ LOQ are reported as “<LOQ”.
    TEXT
  end

  test 'a .doc table row deleted with track changes is left out, the way tracked deletions are in a .docx' do
    assert_equal <<~TEXT.chomp, Readword.convert(fixture('lims_report_deleted_row.doc'))
      Test Report No. 2026/0815

      Customer reference: ABC-123

      Simulant: Ethanol 10% (v/v), 10 days at 40 °C

      | Substance | CAS No. | Result (µg/kg) | LOQ (µg/kg) |
      | --- | --- | --- | --- |
      | Bisphenol A (BPA) | 80-05-7 | <5 | 5 |
      | Toluene | 108-88-3 | 120 ± 15 |  |

      Results ≤ LOQ are reported as “<LOQ”.
    TEXT
  end

  test 'a .doc whose special characters were added with Insert Symbol reads the same as one where they were typed' do
    bytes = fixture('lims_report_symbols.doc')

    assert_includes bytes, '((g/kg)'.encode('UTF-16LE').b
    assert_equal Readword.convert(lims_report_doc), Readword.convert(bytes)
  end

  test 'an Insert Symbol character from a font other than Symbol, such as a Wingdings check mark, is left out of a .doc instead of misread' do
    bytes = fixture('lims_report_symbols.doc')

    assert bytes.sub!([0x6A09, 1, 0xF0B1].pack('v3')) { [0x6A09, 0, 0xF0B1].pack('v3') }

    assert_includes Readword.convert(bytes), '| Toluene | 108-88-3 | 120 15 |  |'
  end

  test 'a .doc keeps its headings, heading numbers, nested bullets, numbered steps and the lists inside table cells' do
    assert_equal <<~TEXT.chomp, Readword.convert(fixture('structured_report.doc'))
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
    TEXT
  end

  test 'a page break inside a .doc paragraph breaks the line without starting a new paragraph' do
    bytes = fixture('lims_report_8bit.doc')

    assert bytes.sub!('Test Report No.') { "Test Report\fNo." }

    assert Readword.convert(bytes).start_with?("Test Report\nNo. 2026/0816\n\nSimulant:")
  end

  test 'a .doc that stores its text as single bytes, the way Word saves Western text, keeps its paragraphs, table rows and special characters' do
    assert_equal <<~TEXT.chomp, Readword.convert(fixture('lims_report_8bit.doc'))
      Test Report No. 2026/0816

      Simulant: Ethanol 10% (v/v), 10 days at 40 °C

      | Substance | Result (µg/kg) | LOQ |
      | --- | --- | --- |
      | Bisphenol A | <5 | 5 |
      | Benzene |  | 10 |

      Uncertainty ± 20 % – “typical”
    TEXT
  end

  test 'field codes, and any fields nested in them, are left out of a .doc while field results stay' do
    bytes = fixture('lims_report_8bit.doc')
            .sub('LOQ') { "\x13X\x15".b }
            .sub('Bisphenol A') { "\x13A\x13B\x14b\x15C\x14Z\x15".b }
            .sub('Benzene') { "\x13AB\x14Bz\x15".b }

    assert_equal <<~TEXT.chomp, Readword.convert(bytes)
      Test Report No. 2026/0816

      Simulant: Ethanol 10% (v/v), 10 days at 40 °C

      | Substance | Result (µg/kg) |  |
      | --- | --- | --- |
      | Z | <5 | 5 |
      | Bz |  | 10 |

      Uncertainty ± 20 % – “typical”
    TEXT
  end

  test 'a .doc using the 0Table stream instead of 1Table reads the same' do
    bytes = lims_report_doc.sub('1Table'.encode('UTF-16LE').b) { '0Table'.encode('UTF-16LE').b }
    flags = bytes.index(WORD_HEADER) + 0x0B
    bytes.setbyte(flags, bytes.getbyte(flags) & ~0x02)

    assert_equal Readword.convert(lims_report_doc), Readword.convert(bytes)
  end

  test 'a .doc with more text than the parser takes is refused as too long before any of it is read' do
    bytes = lims_report_doc.sub([2, 16, 0, 262].pack('CVV2')) { [2, 16, 0, Readword::Doc::TEXT_POSITIONS_PER_MEGABYTE + 1].pack('CVV2') }

    error = assert_raises(Readword::Error) { Readword.convert(bytes, max_size: 1) }

    assert_equal Readword::TOO_LONG, error.reason
  end

  test 'a .doc whose stored text runs past the character limit is still read when its readable text fits' do
    bytes = lims_report_doc.sub([2, 16, 0, 262].pack('CVV2')) { [2, 16, 0, 1_001].pack('CVV2') }

    assert_includes Readword.convert(bytes, max_characters: 1_000), '| Bisphenol A (BPA) | 80-05-7 | <5 | 5 |'
  end

  test 'a password-protected .doc is refused with a message saying so' do
    error = assert_raises(Readword::Error) { Readword.convert(password_protected_lims_report_doc) }

    assert_equal Readword::PASSWORD_PROTECTED, error.reason
  end

  test 'a .doc older than Word 97 is refused with a message saying so' do
    bytes = lims_report_doc
    bytes.setbyte(bytes.index(WORD_HEADER) + 2, 104)

    error = assert_raises(Readword::Error) { Readword.convert(bytes) }

    assert_equal Readword::OLD_FORMAT, error.reason
  end

  test 'an Office file without a Word document inside is refused as unreadable' do
    bytes = lims_report_doc.sub('WordDocument'.encode('UTF-16LE').b, 'WorkDocument'.encode('UTF-16LE').b)

    error = assert_raises(Readword::Error) { Readword.convert(bytes) }

    assert_equal Readword::UNREADABLE, error.reason
  end

  test 'an Office file whose sector chain loops back on itself or points at a sector the file does not have is refused as unreadable instead of hanging' do
    bytes = lims_report_doc
    directory_sector = bytes.unpack1('V', offset: 0x30)
    fat_sector = bytes.unpack1('V', offset: 0x4C)
    next_sector_entry = ((fat_sector + 1) * 512) + (4 * directory_sector)

    [directory_sector, 5000].each do |next_sector|
      bytes[next_sector_entry, 4] = [next_sector].pack('V')
      error = assert_raises(Readword::Error) { Timeout.timeout(5) { Readword.convert(bytes) } }
      assert_equal Readword::UNREADABLE, error.reason
    end
  end

  test 'random bytes, with or without the Office signature, are refused as unreadable instead of crashing' do
    noise = Random.new(4167).bytes(4096)

    [noise, Readword::CompoundFile::SIGNATURE + noise].each do |bytes|
      error = assert_raises(Readword::Error) { Readword.convert(bytes) }
      assert_equal Readword::UNREADABLE, error.reason
    end
  end

  test 'an encrypted .docx, which Word saves as an Office file holding an EncryptedPackage stream, is refused as password-protected' do
    bytes = lims_report_doc
    name_at = bytes.index('WordDocument'.encode('UTF-16LE').b)
    name = "#{'EncryptedPackage'.encode('UTF-16LE').b}\0\0".b
    bytes[name_at, name.bytesize] = name
    bytes[name_at + 64, 2] = [name.bytesize].pack('v')

    error = assert_raises(Readword::Error) { Readword.convert(bytes) }

    assert_equal Readword::PASSWORD_PROTECTED, error.reason
  end

  test 'an RTF file saved with a .doc name is refused as unreadable' do
    error = assert_raises(Readword::Error) { Readword.convert('{\\rtf1\\ansi Benzene 10}') }

    assert_equal Readword::UNREADABLE, error.reason
  end

  test 'a Word file can be read straight from its path' do
    path = File.join(WordDocumentHelper::FIXTURES, 'lims_report.doc')

    assert_equal Readword.convert(lims_report_doc), Readword.convert_file(path)
  end

  test 'Word headings in a .docx become Markdown headings, found by style name, outline level or the style they are based on' do
    styles = [style('Title', 'Title'), style('Heading1', 'heading 1', '<w:outlineLvl w:val="0"/>'), style('Heading2', 'heading 2'),
              style('berschrift3', 'heading 3'), style('ResultsHeading', 'Results heading', based_on: 'Heading2')]
    body = styled('Migration test plan', 'Title') + styled('Scope', 'Heading1') + styled('Simulants', 'Heading2') +
           styled('Conditions', 'berschrift3') + styled('Results', 'ResultsHeading') +
           '<w:p><w:pPr><w:outlineLvl w:val="1"/></w:pPr><w:r><w:t>Outlined</w:t></w:r></w:p>' \
           '<w:p><w:pPr><w:pStyle w:val="Heading1"/><w:outlineLvl w:val="9"/></w:pPr><w:r><w:t>Body text</w:t></w:r></w:p>'

    assert_equal <<~TEXT.chomp, Readword.convert(formatted_docx(body, styles: styles))
      # Migration test plan

      # Scope

      ## Simulants

      ### Conditions

      ## Results

      ## Outlined

      Body text
    TEXT
  end

  test 'bullet and numbered lists in a .docx keep their nesting and the numbers Word shows' do
    abstracts = { '0' => [level(0, 'bullet', 'o'), level(1, 'bullet', 'o')],
                  '1' => [level(0, 'decimal', '%1.'), level(1, 'lowerLetter', '%2)'), level(2, 'lowerRoman', '%3.')] }
    body = listed('Bisphenol A', 1) + listed('food simulant A', 1, 1) + listed('Toluene', 1) + paragraph('Steps') +
           listed('Prepare the sample', 2) + listed('at 40 C', 2, 1) + listed('for 10 days', 2, 1) +
           listed('check daily', 2, 2) + listed('Measure', 2)

    assert_equal <<~TEXT.chomp, Readword.convert(formatted_docx(body, abstracts: abstracts, nums: { '1' => '0', '2' => '1' }))
      - Bisphenol A
        - food simulant A
      - Toluene

      Steps

      1. Prepare the sample
         - a) at 40 C
         - b) for 10 days
           - i. check daily
      2. Measure
    TEXT
  end

  test 'a .docx list restarted in Word counts from its start again, and a list continued later keeps counting' do
    restart = '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride>'
    nums = { '2' => '1', '3' => ['1', restart], '4' => '1' }
    body = listed('first', 2) + listed('second', 2) + paragraph('Then') + listed('again', 3) + listed('and again', 3) +
           paragraph('Later') + listed('continued', 4)

    assert_equal <<~TEXT.chomp, Readword.convert(formatted_docx(body, abstracts: { '1' => [level(0, 'decimal', '%1.')] }, nums: nums))
      1. first
      2. second

      Then

      1. again
      2. and again

      Later

      3. continued
    TEXT
  end

  test 'a .docx list level numbered as none adds nothing to the labels below it, and list level 9 is body text' do
    abstracts = { '1' => [level(0, 'none', '%1'), level(1, 'lowerLetter', '%1%2.')] }
    body = listed('Scope', 2, 1) + listed('Body text', 2, 9)

    assert_equal "- a. Scope\n\nBody text", Readword.convert(formatted_docx(body, abstracts: abstracts, nums: { '2' => '1' }))
  end

  test 'a .docx list that redefines a level keeps counting with its list but shows the new number style' do
    letters = "<w:lvlOverride w:ilvl=\"0\">#{level(0, 'upperLetter', '%1.')}</w:lvlOverride>"
    body = listed('first', 2) + listed('second', 3) + listed('third', 3) + listed('fourth', 2)
    document = formatted_docx(body, abstracts: { '1' => [level(0, 'decimal', '%1.')] }, nums: { '2' => '1', '3' => ['1', letters] })

    assert_equal <<~TEXT.chomp, Readword.convert(document)
      1. first
      - B. second
      - C. third
      4. fourth
    TEXT
  end

  test 'heading numbers that Word takes from a multilevel list show in front of the .docx heading' do
    styles = [style('Heading1', 'heading 1', '<w:numPr><w:numId w:val="5"/></w:numPr>'),
              style('Heading2', 'heading 2', '<w:numPr><w:ilvl w:val="1"/><w:numId w:val="5"/></w:numPr>')]
    abstracts = { '2' => [level(0, 'decimal', '%1', style: 'Heading1'), level(1, 'decimal', '%1.%2', style: 'Heading2')] }
    body = styled('Scope', 'Heading1') + styled('Purpose', 'Heading2') + styled('Limits', 'Heading2') + styled('Method', 'Heading1')

    assert_equal <<~TEXT.chomp, Readword.convert(formatted_docx(body, styles: styles, abstracts: abstracts, nums: { '5' => '2' }))
      # 1 Scope

      ## 1.1 Purpose

      ## 1.2 Limits

      # 2 Method
    TEXT
  end

  test 'list items inside a .docx table cell keep their numbers and bullets in the cell' do
    abstracts = { '0' => [level(0, 'bullet', 'o')], '1' => [level(0, 'decimal', '%1.')] }
    body = table(row(cell(paragraph('Steps')), cell(listed('Prepare', 2) + listed('Measure', 2))),
                 row(cell(paragraph('Simulants')), cell(listed('A', 1) + listed('B', 1))))

    assert_equal <<~TEXT.chomp, Readword.convert(formatted_docx(body, abstracts: abstracts, nums: { '1' => '0', '2' => '1' }))
      | Steps | 1. Prepare 2. Measure |
      | --- | --- |
      | Simulants | • A • B |
    TEXT
  end

  test 'a .docx table row shorter than the first is padded to its width, and pipes inside cells are escaped' do
    body = table(row(cell(paragraph('Substance')), cell(paragraph('Result'))), row(cell(paragraph('A|B'))))

    assert_equal "| Substance | Result |\n| --- | --- |\n| A\\|B |  |", Readword.convert(docx(body))
  end

  test 'a paragraph that starts like Markdown syntax is escaped so it stays text' do
    body = paragraph('# of samples: 5') + paragraph('> 10 mg/kg') + paragraph('| not a table')

    assert_equal "\\# of samples: 5\n\n\\> 10 mg/kg\n\n\\| not a table", Readword.convert(docx(body))
  end

  test 'a document over the size limit reads once the limit is raised' do
    bytes = docx(paragraph('Results') + (' ' * (Readword::MEGABYTE + 1)))

    error = assert_raises(Readword::Error) { Readword.convert(bytes, max_size: 1) }

    assert_equal Readword::TOO_LONG, error.reason
    assert_equal 'Results', Readword.convert(bytes, max_size: 2)
  end

  test 'a size limit of nil or 0 turns the limit off' do
    bytes = docx(paragraph('Results') + (' ' * (Readword::MEGABYTE + 1)))

    assert_equal(['Results'] * 2, [nil, 0].map { |max_size| Readword.convert(bytes, max_size: max_size) })
  end

  test 'each refusal reason has its own message' do
    messages = {
      Readword::UNREADABLE => 'The file could not be read as a Word document (.doc or .docx).',
      Readword::NO_TEXT => 'The Word document has no text.',
      Readword::TOO_LONG => 'The Word document is longer than the reader takes.',
      Readword::PASSWORD_PROTECTED => 'The Word document is password-protected.',
      Readword::OLD_FORMAT => 'The Word document is older than Word 97 (Word 6 or 95), which is not supported.'
    }

    messages.each { |reason, message| assert_equal message, Readword::Error.new(reason).message }
  end

  private

  def paragraph(text)
    "<w:p><w:r><w:t>#{text}</w:t></w:r></w:p>"
  end

  def cell(content, span: nil)
    properties = span ? "<w:tcPr><w:gridSpan w:val=\"#{span}\"/></w:tcPr>" : ''
    "<w:tc>#{properties}#{content}</w:tc>"
  end

  def row(*cells)
    "<w:tr>#{cells.join}</w:tr>"
  end

  def table(*rows)
    "<w:tbl>#{rows.join}</w:tbl>"
  end

  def styled(text, style_id)
    "<w:p><w:pPr><w:pStyle w:val=\"#{style_id}\"/></w:pPr><w:r><w:t>#{text}</w:t></w:r></w:p>"
  end

  def listed(text, num_id, ilvl = 0)
    "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"#{ilvl}\"/><w:numId w:val=\"#{num_id}\"/></w:numPr></w:pPr><w:r><w:t>#{text}</w:t></w:r></w:p>"
  end

  def style(id, name, properties = '', based_on: nil)
    parent = based_on ? "<w:basedOn w:val=\"#{based_on}\"/>" : ''
    "<w:style w:type=\"paragraph\" w:styleId=\"#{id}\"><w:name w:val=\"#{name}\"/>#{parent}<w:pPr>#{properties}</w:pPr></w:style>"
  end

  def level(ilvl, format, text, style: nil)
    linked = style ? "<w:pStyle w:val=\"#{style}\"/>" : ''
    "<w:lvl w:ilvl=\"#{ilvl}\"><w:start w:val=\"1\"/><w:numFmt w:val=\"#{format}\"/>#{linked}<w:lvlText w:val=\"#{text}\"/></w:lvl>"
  end

  def formatted_docx(body, styles: [], abstracts: {}, nums: {})
    lists = abstracts.map { |id, levels| "<w:abstractNum w:abstractNumId=\"#{id}\">#{levels.join}</w:abstractNum>" }
    lists += nums.map do |id, (abstract, overrides)|
      "<w:num w:numId=\"#{id}\"><w:abstractNumId w:val=\"#{abstract}\"/>#{overrides}</w:num>"
    end
    parts = { 'word/styles.xml' => "<w:styles #{NAMESPACES}>#{styles.join}</w:styles>",
              'word/numbering.xml' => "<w:numbering #{NAMESPACES}>#{lists.join}</w:numbering>" }
    relationships = %w[styles numbering].map do |type|
      "<Relationship Id=\"#{type}\" Type=\"#{RELATIONSHIPS}/#{type}\" Target=\"#{type}.xml\"/>"
    end
    docx(body, parts: parts, relationships: relationships.join)
  end

  def docx(body, parts: {}, relationships: '')
    package = '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' \
              "<Relationship Id=\"rId1\" Type=\"#{RELATIONSHIPS}/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
    zip_with(
      '_rels/.rels' => package,
      'word/document.xml' => "<w:document #{NAMESPACES}><w:body>#{body}</w:body></w:document>",
      'word/_rels/document.xml.rels' => "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">#{relationships}</Relationships>",
      **parts
    )
  end
end
