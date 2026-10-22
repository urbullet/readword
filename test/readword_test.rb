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
      Volatiles
      | Toluene | 120 |
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
      assert_equal "Volatiles\n| Toluene | 120 |", Readword.convert(docx(table(row(cell(paragraph('Volatiles') + wrapped)))))
    end
  end

  test 'a table inside a text box in a .docx cell keeps its own rows' do
    inner = table(row(cell(paragraph('Toluene')), cell(paragraph('120'))))
    box = "<w:p><w:r><w:pict><v:textbox><w:txbxContent>#{inner}</w:txbxContent></v:textbox></w:pict></w:r></w:p>"

    text = Readword.convert(docx(table(row(cell(paragraph('Volatiles') + box)))))

    assert_equal ['Volatiles', '| Toluene | 120 |'], text.lines(chomp: true).reject(&:empty?)
  end

  test 'a .docx cell claiming a huge column span fills at most the 63 columns a Word table can have' do
    body = table(row(cell(paragraph('x'), span: 1_000_000_000)))

    assert_equal "| #{(['x'] + ([''] * 62)).join(' | ')} |", Readword.convert(docx(body))
  end

  test 'a .docx with many wide cells is refused as too long once their columns pass the node budget' do
    cells = Array.new(20_000) { cell('<w:p/>', span: Readword::Docx::MAX_GRID_SPAN) }

    error = assert_raises(Readword::Error) { Readword.convert(docx(table(row(*cells)))) }

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

    assert_equal "Result: 15\n3", Readword.convert(docx(body))
  end

  test 'a field nested in the code of another .docx field is left out, so its result is not read twice' do
    inner = '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> DOCVARIABLE Result </w:instrText></w:r>' \
            '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>12</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>'
    result = "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText> IF </w:instrText></w:r>#{inner}" \
             "<w:r><w:instrText> = \"\" \"n.d.\" </w:instrText></w:r>#{inner}" \
             '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>12</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'

    assert_equal '| Benzene | 12 |', Readword.convert(docx(table(row(cell(paragraph('Benzene')), cell(result)))))
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
    bytes = zip_with('word/document.xml' => ' ' * (Readword::Docx::MAX_XML_BYTES + 1))

    error = assert_raises(Readword::Error) { Readword.convert(bytes) }

    assert_equal Readword::TOO_LONG, error.reason
  end

  test 'a .docx whose parts each fit the limit but together do not is refused as too long' do
    padding = ' ' * (Readword::Docx::MAX_XML_BYTES / 2)
    parts = { 'word/header1.xml' => "<w:hdr #{NAMESPACES}>#{paragraph('Example Lab Test Report')}#{padding}</w:hdr>" }
    relationships = "<Relationship Id=\"rId1\" Type=\"#{RELATIONSHIPS}/header\" Target=\"header1.xml\"/>"
    bytes = docx(paragraph('Results') + padding, parts: parts, relationships: relationships)

    error = assert_raises(Readword::Error) { Readword.convert(bytes) }

    assert_equal Readword::TOO_LONG, error.reason
  end

  test 'a .docx with more XML nodes than the reader takes, attributes included, is refused as too long' do
    body = '<w:p w:x="1"/>' * ((Readword::Docx::MAX_XML_NODES / 2) + 1)

    error = assert_raises(Readword::Error) { Readword.convert(docx(body)) }

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

  test 'a .doc that stores its text as single bytes, the way Word saves Western text, keeps its paragraphs, table rows and special characters' do
    assert_equal <<~TEXT.chomp, Readword.convert(fixture('lims_report_8bit.doc'))
      Test Report No. 2026/0816
      Simulant: Ethanol 10% (v/v), 10 days at 40 °C
      | Substance | Result (µg/kg) | LOQ |
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
    bytes = lims_report_doc.sub([2, 16, 0, 262].pack('CVV2')) { [2, 16, 0, Readword::Doc::MAX_TEXT_POSITIONS + 1].pack('CVV2') }

    error = assert_raises(Readword::Error) { Readword.convert(bytes) }

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
