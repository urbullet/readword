# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'rbconfig'
require 'tempfile'

class CliTest < Minitest::Test
  include WordDocumentHelper

  ROOT = File.expand_path('..', __dir__)

  test 'prints a Word document as Markdown and exits cleanly' do
    output, errors, status = readword(fixture_path('lims_report.doc'))

    assert_predicate status, :success?
    assert_empty errors
    assert_equal "#{Readword.convert(lims_report_doc)}\n", output
  end

  test 'reads the document from standard input when the file is -' do
    output, _, status = readword('-', stdin: lims_report_doc)

    assert_predicate status, :success?
    assert_includes output, '| Bisphenol A (BPA) | 80-05-7 | <5 | 5 |'
  end

  test 'puts a header before each document when given several' do
    first = fixture_path('lims_report.doc')
    second = fixture_path('lims_report_8bit.doc')

    output, _, status = readword(first, second)

    assert_predicate status, :success?
    assert output.start_with?("==> #{first} <==\nTest Report No. 2026/0815\n")
    assert_includes output, "\n\n==> #{second} <==\nTest Report No. 2026/0816\n"
  end

  test 'says why a file was refused, keeps going with the rest and exits with 1' do
    Tempfile.create(['notes', '.doc']) do |file|
      file.write('plain text, not a Word file')
      file.close

      output, errors, status = readword(file.path, fixture_path('lims_report.doc'))

      assert_equal 1, status.exitstatus
      assert_equal "readword: #{file.path}: The file could not be read as a Word document (.doc or .docx).\n", errors
      assert_includes output, 'Test Report No. 2026/0815'
    end
  end

  test 'reports a missing file instead of crashing' do
    _, errors, status = readword('missing.docx')

    assert_equal 1, status.exitstatus
    assert_match(/\Areadword: missing\.docx: No such file or directory/, errors)
  end

  test 'refuses a document over the given character limit' do
    _, errors, status = readword('--max-characters', '10', fixture_path('lims_report.doc'))

    assert_equal 1, status.exitstatus
    assert_includes errors, 'The Word document is longer than the reader takes.'
  end

  test 'refuses a document over --max-size, and reads it once the size is raised' do
    namespace = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    body = "<w:p><w:r><w:t>Results</w:t></w:r></w:p>#{' ' * (Readword::MEGABYTE + 1)}"
    Tempfile.create(['big', '.docx']) do |file|
      file.binmode
      file.write(zip_with('word/document.xml' => "<w:document #{namespace}><w:body>#{body}</w:body></w:document>"))
      file.close

      _, errors, = readword('--max-size', '1', file.path)
      output, = readword('--max-size', '2', file.path)

      assert_includes errors, 'The Word document is longer than the reader takes.'
      assert_equal "Results\n", output
    end
  end

  test 'prints the usage when no file is given' do
    _, errors, status = readword

    assert_equal 1, status.exitstatus
    assert_includes errors, 'Usage: readword [options] FILE...'
  end

  private

  def fixture_path(name)
    File.join(WordDocumentHelper::FIXTURES, name)
  end

  def readword(*arguments, stdin: '')
    output, errors, status = Open3.capture3(RbConfig.ruby, '-I', File.join(ROOT, 'lib'), File.join(ROOT, 'exe', 'readword'),
                                            *arguments, stdin_data: stdin, binmode: true)
    [output.force_encoding(Encoding::UTF_8), errors.force_encoding(Encoding::UTF_8), status]
  end
end
