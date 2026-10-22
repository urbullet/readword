# frozen_string_literal: true

require 'zip'

module Readword
  # Reads the text of a Word 2007 or later .docx (ECMA-376 WordprocessingML) from its XML parts.
  class Docx
    MAX_XML_BYTES = 10 * 1024 * 1024
    MAX_XML_NODES = 1_000_000
    MAX_GRID_SPAN = 63
    RELATIONSHIP = %r{/relationships/(officeDocument|header|footer|footnotes|endnotes)\z}
    SKIPPED = %w[del moveFrom instrText delText rPr pPr sectPr tblPr trPr tcPr sdtPr].freeze
    CHARACTERS = %w[t tab ptab br cr noBreakHyphen sym].freeze
    SEPARATOR_NOTES = %w[separator continuationSeparator continuationNotice].freeze

    def initialize(bytes)
      @bytes = bytes
    end

    def lines
      @entries = Zip::File.open_buffer(@bytes).entries.to_h { |entry| [entry.name.downcase, entry] }
      @xml_bytes = 0
      @xml_nodes = 0
      @tables = 0
      main = main_part
      parts = related_parts(main)
      [*unique(parts['header']), *blocks(xml(main)), *notes(parts['footnotes'] + parts['endnotes']),
       *unique(parts['footer'])]
    end

    private

    def main_part
      target = relationships('_rels/.rels').find { |type, _| type == 'officeDocument' }&.last
      target ? resolve('.', target) : 'word/document.xml'
    end

    def related_parts(main)
      directory = File.dirname(main)
      parts = Hash.new { |hash, type| hash[type] = [] }
      seen = Set[main.downcase]
      relationships(File.join(directory, '_rels', "#{File.basename(main)}.rels")).each do |type, target|
        path = resolve(directory, target)
        parts[type] << path if seen.add?(path.downcase)
      end
      parts
    end

    def relationships(path)
      document = xml(path)
      return [] unless document

      document.xpath('//Relationship').filter_map do |relationship|
        type = relationship['Type'].to_s[RELATIONSHIP, 1]
        [type, relationship['Target'].to_s] if type && relationship['TargetMode'] != 'External'
      end
    end

    def resolve(directory, target)
      Pathname.new('/').join(directory, target).cleanpath.to_s.delete_prefix('/')
    end

    def xml(path)
      entry = @entries[path.downcase] or return
      remaining = MAX_XML_BYTES - @xml_bytes
      raise Error, TOO_LONG if entry.size > remaining

      data = entry.get_input_stream { |stream| stream.read(remaining + 1) }.to_s
      raise Error, TOO_LONG if data.bytesize > remaining

      @xml_bytes += data.bytesize
      count_nodes(data.count('<&='))

      Nokogiri::XML(data).tap do |document|
        raise Error, UNREADABLE if document.internal_subset

        document.remove_namespaces!
      end
    end

    def unique(paths)
      paths.flat_map { |path| blocks(xml(path)) }.reject { |line| Readword.blank?(line) }.uniq
    end

    def notes(paths)
      paths.flat_map do |path|
        found = Array(xml(path)&.xpath('//footnote | //endnote'))
        found.reject { |note| SEPARATOR_NOTES.include?(note['type']) }.flat_map { |note| blocks(note) }
      end
    end

    def blocks(node)
      return [] unless node

      node.element_children.flat_map do |child|
        case child.name
        when 'p' then paragraph_lines(child)
        when 'tbl' then table_lines(child)
        when 'AlternateContent' then blocks(alternative(child))
        when *SKIPPED then []
        else blocks(child)
        end
      end
    end

    def paragraph_lines(paragraph)
      boxes = []
      [inline(paragraph, boxes, []), *boxes.flat_map { |box| blocks(box) }]
    end

    def inline(node, boxes, fields)
      node.element_children.map do |child|
        case child.name
        when *CHARACTERS then fields.include?(:code) ? '' : character(child)
        when 'fldChar' then field_char(child['fldCharType'], fields)
        when 'txbxContent'
          boxes << child
          ''
        when 'AlternateContent' then inline(alternative(child), boxes, fields)
        when *SKIPPED then ''
        else inline(child, boxes, fields)
        end
      end.join
    end

    def character(node)
      case node.name
      when 't' then node.text
      when 'tab', 'ptab' then "\t"
      when 'br', 'cr' then "\n"
      when 'noBreakHyphen' then '-'
      when 'sym' then Readword.symbol(node['font'], node['char'].to_s.hex)
      end
    end

    def field_char(type, fields)
      case type
      when 'begin' then fields.push(:code)
      when 'separate' then fields[-1] = :result if fields.last == :code
      when 'end' then fields.pop
      end
      ''
    end

    def alternative(node)
      child_named(node, 'Choice') || child_named(node, 'Fallback') || node
    end

    def table_lines(table)
      @tables += 1
      children_named(table, 'tr').flat_map do |row|
        cells = children_named(row, 'tc')
        tables_before = @tables
        rendered = cells.map { |cell| blocks(cell) }
        next rendered.flatten if @tables > tables_before

        Readword.row_lines(cells.zip(rendered).flat_map { |cell, lines| cell_values(cell, lines) })
      end
    end

    def cell_values(cell, lines)
      span = child_named(child_named(cell, 'tcPr'), 'gridSpan')&.attr('val').to_i.clamp(1, MAX_GRID_SPAN)
      count_nodes(span - 1)
      [Readword.squish(lines.join(' ')), *Array.new(span - 1, '')]
    end

    def count_nodes(count)
      @xml_nodes += count
      raise Error, TOO_LONG if @xml_nodes > MAX_XML_NODES
    end

    def children_named(node, name)
      node.element_children.flat_map do |child|
        next [child] if child.name == name
        next [] if child.name == 'tbl' || SKIPPED.include?(child.name)

        children_named(child, name)
      end
    end

    def child_named(node, name)
      node&.element_children&.find { |child| child.name == name }
    end
  end
end
