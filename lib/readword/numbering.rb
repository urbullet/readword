# frozen_string_literal: true

module Readword
  # List numbers the way Word counts them: one counter per list and level, and deeper levels restart
  # whenever a higher level moves on.
  class Numbering
    Level = Struct.new(:start, :format, :template, :style, keyword_init: true)

    ROMAN = { 1000 => 'M', 900 => 'CM', 500 => 'D', 400 => 'CD', 100 => 'C', 90 => 'XC',
              50 => 'L', 40 => 'XL', 10 => 'X', 9 => 'IX', 5 => 'V', 4 => 'IV', 1 => 'I' }.freeze

    def initialize
      reset
    end

    def reset
      @counts = {}
    end

    def next_item(key, levels, level, starts = {})
      definition = levels[level] or return
      counts = (@counts[key] ||= {})
      counts.delete_if { |deeper, _| deeper > level }
      (0...level).each { |higher| counts[higher] ||= start(levels, higher, starts) }
      counts[level] = counts.key?(level) ? counts[level] + 1 : start(levels, level, starts)
      return ListItem.new(level: level, label: nil, bullet: true, list: key) if definition.format == :bullet

      label = definition.template.map do |part|
        part.is_a?(Integer) ? number(counts[part] || start(levels, part, starts), levels[part]&.format) : part
      end.join.strip
      ListItem.new(level: level, label: label, bullet: false, list: key) unless label.empty?
    end

    private

    def start(levels, level, starts)
      starts[level] || levels[level]&.start || 1
    end

    def number(value, format)
      case format
      when :none then ''
      when :upper_roman then roman(value)
      when :lower_roman then roman(value).downcase
      when :upper_letter then letter(value)
      when :lower_letter then letter(value).downcase
      when :decimal_zero then value.between?(0, 9) ? "0#{value}" : value.to_s
      when :ordinal then ordinal(value)
      else value.to_s
      end
    end

    def roman(value)
      return value.to_s unless value.between?(1, 3999)

      ROMAN.reduce(+'') do |text, (amount, letters)|
        count, value = value.divmod(amount)
        text << (letters * count)
      end
    end

    def letter(value)
      return value.to_s unless value.positive?

      (('A'.ord + ((value - 1) % 26)).chr * (((value - 1) / 26) + 1))
    end

    def ordinal(value)
      suffix = if (11..13).cover?(value % 100) then 'th'
               else { 1 => 'st', 2 => 'nd', 3 => 'rd' }.fetch(value % 10, 'th')
               end
      "#{value}#{suffix}"
    end
  end
end
