# frozen_string_literal: true

require 'zip'

module Readword
  # Reads the text of a Word 2007 or later .docx (ECMA-376 WordprocessingML) from its XML parts.
  class Docx
    MAX_XML_BYTES = 10 * 1024 * 1024
    MAX_XML_NODES = 1_000_000
    MAX_GRID_SPAN = 63
    MAX_STYLE_DEPTH = 16
    RELATIONSHIP = %r{/relationships/(officeDocument|header|footer|footnotes|endnotes|styles|numbering)\z}
    SKIPPED = %w[del moveFrom instrText delText rPr pPr sectPr tblPr trPr tcPr sdtPr].freeze
    CHARACTERS = %w[t tab ptab br cr noBreakHyphen sym].freeze
    SEPARATOR_NOTES = %w[separator continuationSeparator continuationNotice].freeze
    HEADING_STYLE = /\Aheading ([1-9])\z/i
    TITLE_STYLE = /\Atitle\z/i
    LEVEL_REFERENCE = /\A%[1-9]\z/
    FORMATS = { 'upperRoman' => :upper_roman, 'lowerRoman' => :lower_roman, 'upperLetter' => :upper_letter,
                'lowerLetter' => :lower_letter, 'decimalZero' => :decimal_zero, 'ordinal' => :ordinal,
                'bullet' => :bullet, 'none' => :none }.freeze

    def initialize(bytes)
      @bytes = bytes
    end

    def blocks
      @entries = Zip::File.open_buffer(@bytes).entries.to_h { |entry| [entry.name.downcase, entry] }
      @budgets = { content: { bytes: 0, nodes: 0 }, formatting: { bytes: 0, nodes: 0 } }
      @tables = 0
      @counter = Numbering.new
      @chains = {}
      main = main_part
      parts = related_parts(main)
      directory = File.dirname(main)
      @styles = read_styles(xml(parts['styles'].first || File.join(directory, 'styles.xml'), :formatting))
      @lists = read_lists(xml(parts['numbering'].first || File.join(directory, 'numbering.xml'), :formatting))
      [*unique(parts['header']), *part(main), *notes(parts['footnotes'] + parts['endnotes']), *unique(parts['footer'])]
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

    def xml(path, budget = :content)
      entry = @entries[path.downcase] or return
      remaining = MAX_XML_BYTES - @budgets[budget][:bytes]
      raise Error, TOO_LONG if entry.size > remaining

      data = entry.get_input_stream { |stream| stream.read(remaining + 1) }.to_s
      raise Error, TOO_LONG if data.bytesize > remaining

      @budgets[budget][:bytes] += data.bytesize
      count_nodes(data.count('<&='), budget)

      Nokogiri::XML(data).tap do |document|
        raise Error, UNREADABLE if document.internal_subset

        document.remove_namespaces!
      end
    end

    def part(path)
      @counter.reset
      content(xml(path))
    end

    def unique(paths)
      paths.flat_map { |path| part(path) }.reject { |block| block.is_a?(Paragraph) && Readword.blank?(block.text) }.uniq
    end

    def notes(paths)
      paths.flat_map do |path|
        @counter.reset
        found = Array(xml(path)&.xpath('//footnote | //endnote'))
        found.reject { |note| SEPARATOR_NOTES.include?(note['type']) }.flat_map { |note| content(note) }
      end
    end

    def content(node)
      return [] unless node

      node.element_children.flat_map do |child|
        case child.name
        when 'p' then paragraph_blocks(child)
        when 'tbl' then table_blocks(child)
        when 'AlternateContent' then content(alternative(child))
        when *SKIPPED then []
        else content(child)
        end
      end
    end

    def paragraph_blocks(paragraph)
      boxes = []
      text = inline(paragraph, boxes, [])
      properties = child_named(paragraph, 'pPr')
      style = value(properties, 'pStyle')
      block = Paragraph.new(text: text, heading: heading_level(properties, style), list: list_item(properties, style))
      [block, *boxes.flat_map { |box| content(box) }]
    end

    def heading_level(properties, style)
      outline = value(properties, 'outlineLvl') || style_chain(style).filter_map { |entry| entry[:outline] }.first
      level = outline ? outline.to_i : style_chain(style).filter_map { |entry| named_level(entry[:name]) }.first
      [level + 1, 6].min if level&.between?(0, 8)
    end

    def named_level(name)
      return 0 if TITLE_STYLE.match?(name.to_s)

      HEADING_STYLE.match(name.to_s)&.then { |match| match[1].to_i - 1 }
    end

    def list_item(properties, style)
      own = child_named(properties, 'numPr')
      num_id = value(own, 'numId')
      level = value(own, 'ilvl')
      unless num_id
        inherited = style_chain(style).find { |entry| entry[:num_id] }
        num_id = inherited&.fetch(:num_id)
        level ||= inherited&.fetch(:level) || style_level(num_id, style)
      end
      list = @lists[num_id] if num_id && num_id != '0'
      list && @counter.next_item(list[:key], list[:levels], level.to_i.clamp(0, 8), list[:starts])
    end

    def style_level(num_id, style)
      @lists[num_id]&.fetch(:levels)&.find { |_, definition| definition.style == style }&.first
    end

    def style_chain(id)
      @chains[id] ||= begin
        chain = []
        while id && (entry = @styles[id]) && chain.size < MAX_STYLE_DEPTH && !chain.include?(entry)
          chain << entry
          id = entry[:based_on]
        end
        chain
      end
    end

    def read_styles(document)
      return {} unless document

      document.xpath('//style[@type="paragraph"]').to_h do |style|
        properties = child_named(style, 'pPr')
        numbering = child_named(properties, 'numPr')
        [style['styleId'], { name: value(style, 'name'), based_on: value(style, 'basedOn'), outline: value(properties, 'outlineLvl'),
                             num_id: value(numbering, 'numId'), level: value(numbering, 'ilvl') }]
      end
    end

    def read_lists(document)
      return {} unless document

      abstracts = {}
      linked = {}
      document.xpath('//abstractNum').each do |abstract|
        levels = abstract.element_children.select { |child| child.name == 'lvl' }.to_h { |lvl| [lvl['ilvl'].to_i, list_level(lvl)] }
        abstracts[abstract['abstractNumId']] = { levels: levels, link: value(abstract, 'numStyleLink') }
        link = value(abstract, 'styleLink')
        linked[link] = levels if link
      end
      document.xpath('//num').to_h do |num|
        abstract_id = value(num, 'abstractNumId')
        abstract = abstracts.fetch(abstract_id, { levels: {} })
        levels = abstract[:levels].empty? && abstract[:link] ? linked.fetch(abstract[:link], {}) : abstract[:levels]
        overrides = num.element_children.select { |child| child.name == 'lvlOverride' }
        starts = overrides.to_h { |override| [override['ilvl'].to_i, value(override, 'startOverride')] }.compact.transform_values(&:to_i)
        redefined = overrides.filter_map { |override| child_named(override, 'lvl') }
        levels = levels.merge(redefined.to_h { |lvl| [lvl['ilvl'].to_i, list_level(lvl)] })
        [num['numId'], { key: starts.empty? ? "abstract #{abstract_id}" : "num #{num['numId']}", levels: levels, starts: starts }]
      end
    end

    def list_level(lvl)
      Numbering::Level.new(start: value(lvl, 'start')&.to_i, format: FORMATS.fetch(value(lvl, 'numFmt'), :decimal),
                           template: template(value(lvl, 'lvlText').to_s), style: value(lvl, 'pStyle'))
    end

    def template(text)
      text.split(/(%[1-9])/).reject(&:empty?).map { |part| LEVEL_REFERENCE.match?(part) ? part[1].to_i - 1 : part }
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

    def table_blocks(table)
      @tables += 1
      children_named(table, 'tr').flat_map do |row|
        cells = children_named(row, 'tc')
        tables_before = @tables
        rendered = cells.map { |cell| content(cell) }
        next rendered.flatten if @tables > tables_before

        values = cells.zip(rendered).flat_map { |cell, blocks| cell_values(cell, blocks) }
        values.all? { |text| Readword.blank?(text) } ? [] : [Row.new(values)]
      end
    end

    def cell_values(cell, blocks)
      span = value(child_named(cell, 'tcPr'), 'gridSpan').to_i.clamp(1, MAX_GRID_SPAN)
      count_nodes(span - 1)
      [Readword.squish(blocks.map { |block| Markdown.plain(block) }.join(' ')), *Array.new(span - 1, '')]
    end

    def count_nodes(count, budget = :content)
      @budgets[budget][:nodes] += count
      raise Error, TOO_LONG if @budgets[budget][:nodes] > MAX_XML_NODES
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

    def value(node, name)
      child_named(node, name)&.[]('val')
    end
  end
end
