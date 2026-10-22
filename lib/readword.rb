# frozen_string_literal: true

require 'nokogiri'
require 'pathname'
require 'set'
require 'zip'

require_relative 'readword/version'

# Turns Word documents (.doc and .docx) into Markdown text.
module Readword
  SYMBOL_FONT = {
    0x44 => 'Δ', 0x61 => 'α', 0x62 => 'β', 0x63 => 'χ', 0x64 => 'δ', 0x65 => 'ε', 0x67 => 'γ', 0x6B => 'κ',
    0x6C => 'λ', 0x6D => 'µ', 0x70 => 'π', 0x72 => 'ρ', 0x73 => 'σ', 0x74 => 'τ', 0x77 => 'ω', 0xA3 => '≤',
    0xB0 => '°', 0xB1 => '±', 0xB3 => '≥', 0xB4 => '×', 0xB7 => '•', 0xB9 => '≠', 0xBB => '≈'
  }.freeze
  ZIP_SIGNATURE = "PK\x03\x04".b.freeze

  UNREADABLE = :unreadable
  NO_TEXT = :no_text
  TOO_LONG = :too_long
  PASSWORD_PROTECTED = :password_protected
  OLD_FORMAT = :old_format

  MESSAGES = {
    UNREADABLE => 'The file could not be read as a Word document (.doc or .docx).',
    NO_TEXT => 'The Word document has no text.',
    TOO_LONG => 'The Word document is longer than the reader takes.',
    PASSWORD_PROTECTED => 'The Word document is password-protected.',
    OLD_FORMAT => 'The Word document is older than Word 97 (Word 6 or 95), which is not supported.'
  }.freeze

  # Raised when a file cannot be turned into text; #reason is one of the symbols above.
  class Error < StandardError
    attr_reader :reason

    def initialize(reason = UNREADABLE)
      @reason = reason
      super(MESSAGES.fetch(reason))
    end
  end

  def self.convert_file(path, **options)
    convert(File.binread(path), **options)
  end

  def self.convert(bytes, max_characters: nil)
    text = reader(bytes.b).lines.map(&:rstrip).join("\n").gsub(/\n{3,}/, "\n\n").strip
    raise Error, NO_TEXT if text.empty?
    raise Error, TOO_LONG if max_characters && text.size > max_characters

    text
  rescue Error
    raise
  rescue StandardError
    raise Error, UNREADABLE
  end

  def self.reader(bytes)
    if bytes.start_with?(CompoundFile::SIGNATURE) then Doc.new(bytes)
    elsif bytes.start_with?(ZIP_SIGNATURE) then Docx.new(bytes)
    else raise Error, UNREADABLE
    end
  end
  private_class_method :reader

  def self.row_lines(cells)
    cells.all? { |cell| blank?(cell) } ? [] : ["| #{cells.join(' | ')} |"]
  end

  def self.symbol(font, code)
    return SYMBOL_FONT.fetch(code & 0xFF, '') if font.to_s.casecmp?('Symbol')

    code.between?(0x20, 0xD7FF) ? code.chr(Encoding::UTF_8) : ''
  end

  def self.blank?(text)
    text.nil? || text.match?(/\A[[:space:]]*\z/)
  end

  def self.squish(text)
    text.gsub(/[[:space:]]+/, ' ').strip
  end
end

require_relative 'readword/binary'
require_relative 'readword/compound_file'
require_relative 'readword/doc'
require_relative 'readword/docx'
