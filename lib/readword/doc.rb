# frozen_string_literal: true

module Readword
  # Reads the text of a Word 97 to 2003 .doc (MS-DOC) from its WordDocument and table streams.
  class Doc
    include Binary

    Piece = Struct.new(:start, :finish, :offset, :compressed)
    Run = Struct.new(:start, :finish, :flags)

    # FibBase: wIdent is always 0xA5EC, and an nFib below 106 means Word 6 or 95.
    WORD_IDENT = 0xA5EC
    FIRST_WORD97_VERSION = 106
    # Byte offsets into the FIB, the header at the start of the WordDocument stream (FibBase, FibRgFcLcb97).
    FIB_VERSION = 0x02
    FIB_FLAGS = 0x0A
    FIB_CHPX_TABLE = 0x00FA
    FIB_CHPX_TABLE_BYTES = 0x00FE
    FIB_PAPX_TABLE = 0x0102
    FIB_PAPX_TABLE_BYTES = 0x0106
    FIB_FONT_TABLE = 0x0112
    FIB_FONT_TABLE_BYTES = 0x0116
    FIB_PIECE_TABLE = 0x01A2
    FIB_PIECE_TABLE_BYTES = 0x01A6
    FIB_MIN_BYTES = 0x01AA
    # FibBase flag bits fEncrypted and fWhichTblStm (set means the 1Table stream).
    ENCRYPTED = 0x0100
    TABLE_STREAM_ONE = 0x0200
    # FcCompressed: bit 30 set means 8-bit Windows-1252 text stored at half the offset.
    COMPRESSED_TEXT = 0x40000000
    TEXT_OFFSET = 0x3FFFFFFF
    # Formatting is stored in 512-byte FKP pages of at most 29 paragraph runs or 101 character runs.
    PAGE_BYTES = 512
    MAX_PAPX_RUNS_PER_PAGE = 0x1D
    MAX_CHPX_RUNS_PER_PAGE = 0x65
    # Limits against crafted files, so the reader cannot be made to work forever.
    MAX_PROPERTY_BYTES = 8 * 1024 * 1024
    MAX_TEXT_POSITIONS = 400_000

    # Paragraph sprms: in a table, end of a table row, and the same two for a table nested in a cell.
    PARAGRAPH_SPRMS = { 0x2416 => :in_table, 0x2417 => :row_end, 0x244B => :inner_cell, 0x244C => :inner_row_end }.freeze
    # sprmCFRMarkDel: deleted with Track Changes. Word writes 1, or 0x81, a ToggleOperand meaning the opposite of the style.
    DELETED = 0x0800
    DELETED_VALUES = [0x01, 0x81].freeze
    # sprmCSymbol: Insert Symbol stores "(" in the text, and the font number and real character here.
    SYMBOL = 0x6A09
    SYMBOL_PLACEHOLDER = '('
    # FFN, one font in the SttbfFfn table: its name starts after 40 bytes of size, flags, weight, charset, panose and signature.
    FONT_NAME_OFFSET = 40
    # sprmPItap (table depth), sprmPHugePapx (properties kept in the Data stream), and two sprms with unusual operand sizes.
    TABLE_DEPTH = 0x6649
    HUGE_PAPX = 0x6646
    DEFINE_TABLE = 0xD608
    CHANGE_TABS = 0xC615

    # Special characters in the text: field begin, separator and end, the cell mark, the paragraph mark, and page and column breaks.
    FIELD_BEGIN = "\u0013"
    FIELD_SEPARATOR = "\u0014"
    FIELD_END = "\u0015"
    CELL_MARK = "\a"
    PARAGRAPH_ENDS = ["\r", "\f", "\u000E"].freeze
    REPLACEMENTS = { "\v" => "\n", "\t" => "\t", "\u001E" => '-', "\u00A0" => ' ' }.freeze
    CP1252 = Array.new(256) do |byte|
      byte.chr.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, undef: :replace, replace: '')
    end.freeze

    def initialize(bytes)
      @file = CompoundFile.new(bytes)
      @word = @file.stream('WordDocument').to_s
      raise Error, PASSWORD_PROTECTED if @word.empty? && @file.stream?('EncryptedPackage')
      raise Error, OLD_FORMAT if u16(@word, FIB_VERSION).to_i.between?(1, FIRST_WORD97_VERSION - 1)
      raise Error, UNREADABLE unless @word.bytesize >= FIB_MIN_BYTES && u16(@word, 0) == WORD_IDENT
      raise Error, PASSWORD_PROTECTED if fib_flags.anybits?(ENCRYPTED)

      @table = @file.stream(fib_flags.anybits?(TABLE_STREAM_ONE) ? '1Table' : '0Table') || raise(Error, UNREADABLE)
    end

    def blocks
      pieces = text_pieces
      raise Error, TOO_LONG if pieces.sum { |piece| [piece.finish - piece.start, 0].max } > MAX_TEXT_POSITIONS

      @property_bytes = 0
      @runs = paragraph_runs
      @marked = marked_runs
      @blocks = []
      @row = []
      @text = +''
      read_characters(pieces)
      if @row.any?
        end_row
      else
        @blocks << Paragraph.new(text: @text)
      end
      @blocks
    end

    private

    # Field codes sit between a field begin and its separator; only the result after the separator is text.
    def read_characters(pieces)
      fields = []
      code_depth = 0
      each_character(pieces) do |character, offset|
        marks = @marked.empty? ? {} : run_flags(@marked, offset)
        next if marks[:deleted]

        character = font_symbol(*marks[:symbol]) if marks[:symbol] && character == SYMBOL_PLACEHOLDER
        case character
        when FIELD_BEGIN
          fields.push(:code)
          code_depth += 1
        when FIELD_SEPARATOR
          if fields.last == :code
            fields[-1] = :result
            code_depth -= 1
          end
        when FIELD_END
          code_depth -= 1 if fields.pop == :code
        else
          read_character(character, offset) if code_depth.zero?
        end
      end
    end

    def read_character(character, offset)
      if character == CELL_MARK
        paragraph_flags(offset)[:row_end] ? end_row : end_cell
      elsif PARAGRAPH_ENDS.include?(character)
        end_paragraph(paragraph_flags(offset))
      elsif character >= ' ' || REPLACEMENTS.key?(character)
        @text << REPLACEMENTS.fetch(character, character)
      end
    end

    def end_paragraph(flags)
      if flags[:inner_row_end] then end_row
      elsif flags[:inner_cell] then end_cell
      elsif flags[:in_table] then @text << ' '
      else
        end_row if @row.any?
        @blocks << Paragraph.new(text: @text)
        @text = +''
      end
    end

    def end_cell
      @row << Readword.squish(@text)
      @text = +''
    end

    def end_row
      end_cell unless Readword.blank?(@text)
      @blocks << Row.new(@row) unless @row.all? { |cell| Readword.blank?(cell) }
      @row = []
      @text = +''
    end

    def each_character(pieces, &)
      pieces.each do |piece|
        count = piece.finish - piece.start
        next unless count.positive?

        if piece.compressed
          @word.byteslice(piece.offset, count).to_s.each_byte.with_index { |byte, index| yield CP1252[byte], piece.offset + index }
        else
          each_utf16(@word.byteslice(piece.offset, count * 2).to_s.unpack('v*'), piece.offset, &)
        end
      end
    end

    def each_utf16(units, offset)
      index = 0
      while index < units.size
        unit = units[index]
        low = units[index + 1].to_i
        if unit.between?(0xD800, 0xDBFF) && low.between?(0xDC00, 0xDFFF)
          yield (0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)).chr(Encoding::UTF_8), offset + (2 * index)
          index += 1
        elsif !unit.between?(0xD800, 0xDFFF)
          yield unit.chr(Encoding::UTF_8), offset + (2 * index)
        end
        index += 1
      end
    end

    # Clx: optional Prc entries (clxt 1), then a Pcdt (clxt 2) whose PlcPcd lists where each run of text is stored.
    def text_pieces
      clx = @table.byteslice(u32(@word, FIB_PIECE_TABLE), u32(@word, FIB_PIECE_TABLE_BYTES)).to_s
      position = 0
      position += 3 + u16(clx, position + 1) while clx.getbyte(position) == 0x01
      raise Error, UNREADABLE unless clx.getbyte(position) == 0x02

      table = clx.byteslice(position + 5, u32(clx, position + 1).to_i).to_s
      count = (table.bytesize - 4) / 12
      raise Error, UNREADABLE unless count.positive?
      raise Error, TOO_LONG if count > MAX_TEXT_POSITIONS

      positions = table.unpack("V#{count + 1}")
      Array.new(count) do |index|
        fc = u32(table, (4 * (count + 1)) + (8 * index) + 2)
        compressed = fc.anybits?(COMPRESSED_TEXT)
        offset = fc & TEXT_OFFSET
        Piece.new(positions[index], positions[index + 1], compressed ? offset / 2 : offset, compressed)
      end
    end

    def paragraph_runs
      property_pages(FIB_PAPX_TABLE, FIB_PAPX_TABLE_BYTES).flat_map { |offset| page_runs(offset) }.sort_by(&:start)
    end

    def marked_runs
      runs = property_pages(FIB_CHPX_TABLE, FIB_CHPX_TABLE_BYTES).flat_map { |offset| character_runs(offset) }
      runs.select { |run| run.flags[:deleted] || run.flags[:symbol] }.sort_by(&:start)
    end

    # PlcBtePapx and PlcBteChpx: FC boundaries, then the FKP page numbers in the low 22 bits.
    def property_pages(table_at, bytes_at)
      table = @table.byteslice(u32(@word, table_at), u32(@word, bytes_at)).to_s
      count = (table.bytesize - 4) / 8
      return [] unless count.positive?

      limit = [count, @word.bytesize / PAGE_BYTES].min
      table.unpack("@#{4 * (count + 1)}V#{limit}").map { |page| (page & 0x3FFFFF) * PAGE_BYTES }.uniq
    end

    # PapxFkp: run boundaries, then 13-byte BxPap entries whose first byte, doubled, points at the run's PapxInFkp.
    def page_runs(offset)
      page = @word.byteslice(offset, PAGE_BYTES).to_s
      return [] unless page.bytesize == PAGE_BYTES

      count = page.getbyte(PAGE_BYTES - 1)
      return [] unless count.between?(1, MAX_PAPX_RUNS_PER_PAGE)

      bounds = page.unpack("V#{count + 1}")
      properties = {}
      Array.new(count) do |index|
        at = page.getbyte((4 * (count + 1)) + (13 * index)) * 2
        Run.new(bounds[index], bounds[index + 1], at.zero? ? {} : (properties[at] ||= papx_flags(page, at)))
      end
    end

    # ChpxFkp: run boundaries, then 1-byte offsets that, doubled, point at each run's Chpx.
    def character_runs(offset)
      page = @word.byteslice(offset, PAGE_BYTES).to_s
      return [] unless page.bytesize == PAGE_BYTES

      count = page.getbyte(PAGE_BYTES - 1)
      return [] unless count.between?(1, MAX_CHPX_RUNS_PER_PAGE)

      bounds = page.unpack("V#{count + 1}")
      properties = {}
      Array.new(count) do |index|
        at = page.getbyte((4 * (count + 1)) + index) * 2
        Run.new(bounds[index], bounds[index + 1], at.zero? ? {} : (properties[at] ||= chpx_flags(page, at)))
      end
    end

    # PapxInFkp: a size byte (0 means the next byte holds it), then a 2-byte style index and the sprms.
    def papx_flags(page, offset)
      size = page.getbyte(offset) or return {}
      length, start = size.zero? ? [2 * page.getbyte(offset + 1).to_i, offset + 2] : [(2 * size) - 1, offset + 1]
      sprm_flags(page.byteslice(start + 2, length - 2).to_s)
    end

    def chpx_flags(page, offset)
      size = page.getbyte(offset) or return {}
      sprm_flags(page.byteslice(offset + 1, size).to_s)
    end

    def sprm_flags(grpprl, nested: false)
      @property_bytes += grpprl.bytesize
      raise Error, UNREADABLE if @property_bytes > MAX_PROPERTY_BYTES

      flags = {}
      position = 0
      while position + 2 <= grpprl.bytesize
        sprm = u16(grpprl, position)
        size = operand_size(sprm, grpprl, position + 2) or break
        operand = grpprl.byteslice(position + 2, size).to_s
        if PARAGRAPH_SPRMS.key?(sprm) then flags[PARAGRAPH_SPRMS[sprm]] = operand.getbyte(0) == 1
        elsif sprm == DELETED then flags[:deleted] = DELETED_VALUES.include?(operand.getbyte(0))
        elsif sprm == SYMBOL then flags[:symbol] = [u16(operand, 0).to_i, u16(operand, 2).to_i]
        elsif sprm == TABLE_DEPTH then flags[:in_table] ||= u32(operand, 0).to_i.positive?
        elsif sprm == HUGE_PAPX && !nested then flags.merge!(huge_papx_flags(u32(operand, 0).to_i))
        end
        position += 2 + size
      end
      flags
    end

    # The sprm's top 3 bits (spra) give its operand size; 6 means the size is stored in the operand itself.
    def operand_size(sprm, grpprl, offset)
      case sprm >> 13
      when 0, 1 then 1
      when 2, 4, 5 then 2
      when 3 then 4
      when 7 then 3
      else variable_operand_size(sprm, grpprl, offset)
      end
    end

    def variable_operand_size(sprm, grpprl, offset)
      return u16(grpprl, offset).to_i + 1 if sprm == DEFINE_TABLE

      size = grpprl.getbyte(offset) or return
      size + 1 unless sprm == CHANGE_TABS && size == 255
    end

    def huge_papx_flags(offset)
      @huge_papx ||= {}
      @huge_papx[offset] ||= begin
        @data ||= @file.stream('Data').to_s
        size = u16(@data, offset)
        size ? sprm_flags(@data.byteslice(offset + 2, size).to_s, nested: true) : {}
      end
    end

    def paragraph_flags(offset)
      run_flags(@runs, offset)
    end

    def run_flags(runs, offset)
      index = (runs.bsearch_index { |run| run.start > offset } || runs.size) - 1
      return {} if index.negative?

      run = runs[index]
      offset < run.finish ? run.flags : {}
    end

    def font_symbol(font, code)
      Readword.symbol(font_names[font], code)
    end

    def font_names
      @font_names ||= begin
        table = @table.byteslice(u32(@word, FIB_FONT_TABLE), u32(@word, FIB_FONT_TABLE_BYTES)).to_s
        position = 4
        Array.new(u16(table, 0).to_i) do
          size = table.getbyte(position).to_i + 1
          name = table.byteslice(position + FONT_NAME_OFFSET, size - FONT_NAME_OFFSET).to_s
          position += size
          name.unpack('v*').take_while(&:nonzero?).pack('U*').scrub('')
        end
      end
    end

    def fib_flags
      u16(@word, FIB_FLAGS)
    end
  end
end
