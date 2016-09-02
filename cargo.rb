#!/usr/bin/env ruby

require 'open-uri'
require 'net/http'
require 'cgi'
require 'optparse'
require 'date'
require 'inquirer'

options = {}
OptionParser.new do |opts|
  opts.banner = 'Usage: cargo [options] [filter/urls]'

  opts.on('-m', '--movies', 'Show movies in the list') do |v|
    options[:movies] = v
  end

  opts.on('-w', '--wget', "Use 'wget' for the downloads instead of the default 'axel'") do |v|
    options[:wget] = v
    if options[:wget] && `which wget`.strip == ''
      puts 'Wget is not installed. Please install it with `brew` and try again.'
      exit
    end
  end

  opts.on('-d', '--direct-download', 'Download from the provided UpToBox/Go4Up links') do |_links|
    options[:urls] = ARGV.join(' ')
  end

  opts.separator ''
  opts.separator 'Examples:'
  opts.separator '    cargo detective'
  opts.separator '    cargo -w'
  opts.separator '    cargo -d http://uptobox.com/hrfow01yixy4 http://go4up.com/dl/7a3115e52d50'
end.parse!

if !options[:wget] && `which axel`.strip == ''
  puts 'Axel is not installed. Defaulting to wget...'
  options[:wget] = true
  if `which wget`.strip == ''
    puts 'Wget is not installed. Please install it with `brew` and try again.'
    exit
  end
end

options[:filter] = ARGV.join(' ') unless ARGV.empty?

# A helper class for formatting exceptions in logs
class PrettyError
  def initialize(message = nil, exception = StandardError.new, full_backtrace = false)
    @message = message
    @exception = exception
    @full_backtrace = full_backtrace
  end

  def to_s
    lines = []
    lines << '*Additional message: ' + @message if @message
    lines << "*Error: #{@exception}"

    if @exception.backtrace
      line = '*Backtrace: ' + @exception.backtrace.first
      line = "*Backtrace: \n\t" + @exception.backtrace.join("\n\t") if @full_backtrace
      lines << line
    end

    "Caught Exception: #{@exception.class} {\n#{lines.join("\n")}\n}"
  end
end

# A link scanner for handling all the supported hosters and scanning for their links
class LinkScanner
  def self.scan_for_ub_links(text)
    direct = text.scan(%r{http://(?:www\.)?uptobox\.com/[a-z\d]{12}}im).flatten.uniq
    text.scan(%r{go4up.com/dl/[a-z\d]{12,14}}im).flatten.uniq.collect do |go4up_link|
      s = open("http://#{go4up_link.gsub('/dl/', '/rd/')}/2").read.to_s
      s = s.scan(%r{http://(?:www\.)?uptobox\.com/[a-z\d]{12}}im).flatten.uniq
      direct += s
    end

    direct
  end

  def self.get(links_of_interest)
    UpToBox.check_urls(links_of_interest) || []
  rescue StandardError => e
    puts PrettyError.new("Couldn't check the given links.", e, true)
    nil
  end

  def self.scan_and_get(text)
    links = LinkScanner.scan_for_ub_links(text)

    LinkScanner.get(links)
  end
end

# A helper class for formatting and syntax sugar
class Helper
  def self.put_header(message = nil)
    puts message if message
    puts '-' * 50
  end

  # bytes -> human readable size
  def self.human_size(n, base = 8)
    return '0' if n.nil?

    units = %w(B KB MB GB)

    unit = units[0]
    unit_size = base == 8 ? 1024 : 1000
    size = n

    if n.instance_of? String
      unit = n[-2, 2]
      size = n[0..-2].to_f
    end

    if size >= unit_size
      human_size((size / unit_size).to_s + units[units.index(unit) + 1], base)
    else
      if size == size.to_i
        return size.to_i.to_s + unit
      else
        index = size.to_s.index('.')

        return size.to_s[0..(index - 1)] + unit if units.index(unit) < 2

        begin
          size.to_s[0..(index + 2)] + unit
        rescue
          size.to_s[0..(index + 1)] + unit
        end
      end
    end
  end

  # time -> minimalist date+time
  def self.human_time(time)
    time = Time.at(time.to_i) unless time.is_a?(Time)
    twelveclock = false

    day = ''
    now = Time.now
    if time.day != now.day || time.month != now.month || time.year != now.year
      tmp = now - 86_400
      is_yesterday = (time.day == tmp.day && time.month == tmp.month && time.year == tmp.year)

      day = if is_yesterday
              'yesterday'
            else
              time.strftime('%-d %b')
            end
    end

    day + ' ' + (twelveclock ? time.strftime('%I:%M%P') : time.strftime('%H:%M'))
  end

  # time -> relative
  def self.relative_time(time)
    time = Time.at(time.to_i) unless time.is_a?(Time)

    now = Time.now
    diff = now - time
    hours_ago = (diff / 3600).to_i
    minutes_ago = (diff / 60).to_i

    if hours_ago < 24
      hours_ago > 0 ? "#{hours_ago}h ago" : "#{minutes_ago}m ago"
    else
      "#{hours_ago / 24}d ago"
    end
  end

  def self.to_bytes(size)
    number = size.to_f
    unit = size.to_s.gsub(/[^a-zA-Z]/, '')

    return number.to_i if unit.empty?

    # units = ['b', 'k', 'm', 'g']
    # 1024 ** (units.index(unit.downcase[0]) + 1)
    if unit.casecmp('k').zero? || unit.casecmp('kb').zero?
      (number * 1024).to_i
    elsif unit.casecmp('m').zero? || unit.casecmp('mb').zero?
      (number * 1024 * 1024).to_i
    elsif unit.casecmp('g').zero? || unit.casecmp('gb').zero?
      (number * 1024 * 1024 * 1024).to_i
    else
      number.to_i
    end
  end

  def self.escape_url(url)
    CGI.escape(url).gsub(' ', '%20').gsub('+', '%20')
  end

  def self.attempt(max_tries)
    return nil if max_tries < 1

    tries = 0
    begin
      yield
    rescue StandardError => e
      tries += 1
      if tries < max_tries
        retry
      else
        puts PrettyError.new(nil, e)
      end
    end
  end

  def self.attempt_and_raise(max_tries)
    return nil if max_tries < 1

    tries = 0
    begin
      yield
    rescue StandardError => e
      tries += 1
      retry if tries < max_tries
      raise e
    end
  end
end

# UpToBox hoster support class
class UpToBox
  def self.check_urls(urls)
    files = []

    urls.each do |url|
      next if url.match(%r{http://(?:www\.)?uptobox\.com/[a-z\d]{12}}im).nil?
      files << check_file(url)
    end

    organize(files.compact)
  end

  def self.check_file(url)
    page, dead = nil

    Helper.attempt_and_raise(3) do
      resp = Net::HTTP.get_response(URI(url))
      page = resp.body
      dead = (resp.code.to_i != 200)
    end

    id = url.split('/').last

    if dead
      puts "#{url} - Dead link"
      rand, filename, noextension = 'DEAD'
      size = '0'
    else
      rand = page.scan(/(?:'|")rand(?:'|") value=(?:'|")(.*?)(?:'|")/im).flatten.first
      fname = page.scan(/(?:'|")fname(?:'|") value=(?:'|")(.*?)(?:'|")/im).flatten.first
      size = page.scan(/para_title.*?\(\s*(.*?)\s*\)/im).flatten.first
      cleaner = '?_?))looc|skcor|gro|ten:?(.\\:?(yellavldd?_'.reverse
      filename = fname.gsub(/#{cleaner}/im, '')

      noextension = filename.split('.')[0..-2].join('.')
      noextension = noextension.split('.')[0..-2].join('.') if noextension =~ /part\d+$/
    end

    {
      url: url, id: id, rand: rand,
      fname: fname, filename: filename, noextension: noextension,
      dead: dead, size: Helper.to_bytes(size)
    }
  end

  def self.organize(files)
    # detect multipart files and organize them in groups
    grouped_files = []
    files.each do |file|
      if file[:dead]
        grouped_files << { name: file[:url], files: [], dead: true }
        next
      end

      correct_group = grouped_files.find { |group| group[:name] == file[:noextension] }
      if correct_group
        correct_group[:files] << file
        next
      end

      is_multipart_name = (file[:filename] =~ /\.part\d+\.rar$/i)
      new_group_name = is_multipart_name ? file[:noextension] : file[:filename]
      grouped_files << { name: new_group_name, files: [file] }
    end

    # calculate total size for each group
    grouped_files.each do |group|
      group[:size] = 0
      group[:host] = 'UpToBox'

      group[:files].each do |file|
        group[:size] += file[:size].to_i
      end

      group[:noextension] = group[:files].first[:noextension]
      group[:name] = group[:files].first[:filename] if group[:files].count == 1
    end

    grouped_files
  end

  def self.get_download_link(file, last_time = false)
    return nil if file.nil? || file[:dead]

    directlink = nil

    Helper.attempt(3) do
      result = nil

      loop do
        uri = URI(file[:url])
        http = Net::HTTP.new(uri.host)
        data = "rand=#{file[:rand]}&op=download2&id=#{file[:id]}&referer="\
               "&method_free=&method_premium&down_direct=1&fname=#{file[:fname]}"
        result = http.post(uri.path, data, 'Referer' => file[:url])

        wait_message = result.body.scan(%r{(You have to wait.*?)<br}i).flatten.first
        wait = !wait_message.nil?

        skipped_countdown = !result.body.scan(/Skipped countdown/i).flatten.first.nil?

        if wait
          puts wait_message
          sleep 60
        elsif skipped_countdown
          puts 'Waiting for countdown...'
          sleep 120
        else
          break
        end
      end

      directlink = result.body.scan(%r{(http://.{1,10}\.uptobox.com/d/.*?)(?:'|")}i).flatten.first

      if !directlink || !directlink.include?('uptobox.com/d/')
        raise StandardError, "Couldn't get direct link for download."
      end
    end

    if (directlink.nil? || directlink.empty?) && !last_time
      puts 'Trying again with a new download session...'
      directlink = get_download_link(check_file(file[:url]), true)
    elsif (directlink.nil? || directlink.empty?) && last_time
      puts 'Skipping. Servers might be down.'
    end

    (directlink.nil? || directlink.empty?) ? nil : directlink
  end

  def self.download(url)
    file = UpToBox.check_file(url)
    return nil if file.nil? || file[:dead]

    directlink = UpToBox.directlink(file)

    [file[:filename], directlink]
  end
end

# Handling the source website's loading, scanning and other tasks.
class Shows
  @website = 'looc.yellavldd'.reverse # don't attract search engines!
  @us_regex = /(?:-|\.)S\d{2}(E\d{2}){1,2}(?:-|\.)/i
  @uk_regex = /(?:-|\.)\d{1,2}x\d{2}(?:-|\.)/i
  @other_regex = /(?:-|\.)\d{4}(?:-|\.)\d{2}(?:-|\.)\d{2}(?:-|\.)/i
  @strict_us_regex = /\A[^\s]+(?:-|\.)S\d{2}(E\d{2}){1,2}(?:-|\.)[^\s]+\z/i
  @strict_uk_regex = /\A[^\s]+(?:-|\.)\d{1,2}x\d{2}(?:-|\.)[^\s]+\z/i
  @strict_other_regex = /\A[^\s]+(?:-|\.)\d{4}(?:-|\.)\d{2}(?:-|\.)\d{2}(?:-|\.)[^\s]+\z/i
  @weird_regex = /Download (.*?) Here/i

  def self.sm_url
    month = Time.now.month.to_s
    month = "0#{month}" if month.length == 1

    "http://www.#{@website}/sitemap-pt-post-#{Time.now.year}-#{month}.xml"
  end

  def self.old_sm_url
    month = (Time.now.month - 1).to_s
    month = "0#{month}" if month.length == 1

    "http://www.#{@website}/sitemap-pt-post-#{Time.now.year}-#{month}.xml"
  end

  def self.on_demand(filter = nil, show_movies = false)
    result = []

    website = @website.gsub('.', '\\.')
    sm_regex = %r{<loc>(http://(?:www\.)?#{website}/([^<]+?))/</loc>.*?<lastmod>(.*?)</lastmod>}im

    sitemap = open(sm_url).read.to_s
    releases = sitemap.scan(sm_regex).uniq
    sitemap = open(old_sm_url).read.to_s
    releases += sitemap.scan(sm_regex).uniq

    # only keep shows in the array if not specified
    unless show_movies
      releases = releases.collect do |release|
        rname = release[1]
        release if (rname =~ @us_regex) || (rname =~ @uk_regex) || (rname =~ @other_regex)
      end.compact.take(200)
    end

    releases.each do |_url, release_name, lastmod|
      formatted_name = release_name.gsub(/-|_|\./, ' ')
      parts = formatted_name.split(' ').compact

      parts = parts.collect do |word|
        word = word.capitalize unless %w(and of with in x264).include?(word)
        word = word.upcase if %w(au us uk ca hdtv xvid pdtv web dl).include?(word.downcase)
        word = word.upcase if word =~ /s\d{2}e\d{2}/i
        word
      end

      parts << parts.pop.upcase unless parts.empty?

      formatted_name = parts.join(' ')

      if filter.nil? || (filter && formatted_name.downcase.include?(filter.downcase))
        relative_time = Helper.relative_time(DateTime.parse(lastmod).to_time)
        result << ["(#{relative_time}) #{formatted_name}", release_name]
      end
    end

    result
  end

  def self.releases_for(reference)
    source = (open "http://#{@website}/#{CGI.escape(reference)}").read.to_s

    # remove sections that contain multipart links because we have better one-click links
    source = source.gsub(/info3.*?info2/im, '')

    # try to get the correct names of the files
    possible_release_names = source.scan(%r{<strong>(.*?)</strong>}im).flatten
    possible_release_names.collect! do |rname|
      rname =~ @weird_regex ? rname.match(@weird_regex)[1] : rname
    end
    possible_release_names.keep_if do |rname|
      (rname =~ @strict_us_regex) || (rname =~ @strict_uk_regex) || (rname =~ @strict_other_regex)
    end

    [LinkScanner.scan_for_ub_links(source), possible_release_names]
  end
end

# A selection menu/paginator class based on Inquirer with custom actions
class List
  def run(clear, response)
    # finish if there's nothing to do
    return nil if Array(@elements).empty?

    get_next = false
    get_prev = false
    quit = false

    # hides the cursor while prompting
    IOHelper.without_cursor do
      # render the
      IOHelper.render(update_prompt)
      # loop through user input
      IOHelper.read_key_while do |key|
        @pos = (@pos - 1) % @elements.length if key == 'up'
        @pos = (@pos + 1) % @elements.length if key == 'down'
        get_next = (key == 'down' && @pos == 0) || (key == 'right')
        get_prev = (key == 'up' && @pos == 0) || (key == 'left')

        IOHelper.rerender(update_prompt)
        # we are done if the user hits return

        quit = key == 'q'
        get_next ||= (key == 'n')
        get_prev ||= (key == 'p')

        key != 'return' && !quit && !get_next && !get_prev
      end
    end

    # clear the final prompt and the line
    IOHelper.clear if clear

    # show the answer
    IOHelper.render(update_response) if response && !get_next && !get_prev

    # return the index of the selected item
    return -1 if get_next
    return -2 if get_prev
    return -3 if quit
    @pos
  end

  def self.list_paginate(*args)
    List.ask_paginate(*args)
  end

  def self.ask_paginate(question = nil, elements = [], opts = {})
    l = List.new question, elements, opts[:renderer], opts[:rendererResponse]

    l.all_elements = elements
    l.page = 1
    selected = -3

    loop do
      selected = l.run opts.fetch(:clear, true), opts.fetch(:response, true)
      if selected == -1
        l.page = l.page + 1 if l.page < l.pages_count
      elsif selected == -2
        l.page = l.page - 1 if l.page > 1
      else
        break
      end
    end

    selected != -3 ? selected + l.offset : selected
  end

  attr_writer :all_elements

  attr_writer :elements

  attr_reader :page

  def page=(p)
    @page = p
    @elements = current_page_elements
  end

  def pages_count
    (@all_elements.count / elements_per_page).ceil
  end

  def offset
    (@page - 1) * elements_per_page
  end

  def elements_per_page
    20
  end

  def current_page_elements
    @all_elements[(offset)..-1].take(elements_per_page)
  end

  def update_prompt
    # transform the list into
    # {"value"=>..., "selected"=> true|false}
    e = @elements.map.with_index(0).map do |c, pos|
      { 'value' => c, 'selected' => pos == @pos }
    end
    # call the renderer
    q = @question
    q += " (page #{@page})" if @page && pages_count > 1
    @prompt = @renderer.render(q, e)
  end
end

# The class handling the main tasks of the script
class Main
  def self.print_releases(releases)
    shown_releases = releases.collect(&:first)

    if shown_releases.count == 0
      Helper.put_header 'No results.'
      exit
    elsif shown_releases.count == 1
      Helper.put_header 'Single result, proceeding...'
      return 0
    end

    selected = List.list_paginate "Choose a release (nav. using arrows and 'n', 'p') ",
                                  shown_releases
    exit if selected == -3
    selected
  end

  def self.groups_from_links(links, release_names = nil)
    if links.empty? || links.nil?
      puts 'No links'
      exit
    end
    groups = LinkScanner.get(links)
    if groups.nil?
      puts 'No valid links'
      exit
    end

    match_groups_with_releases(groups, release_names)
  end

  def self.match_groups_with_releases(groups, releases)
    return groups unless releases

    groups.each do |group|
      group_name = group[:noextension].downcase.split(/[-\.]/)
      releases.each do |rname|
        next unless rname.downcase.split(/[-\.]/).last == group_name.last

        r720 = rname.downcase.include?('720p')
        r1080 = rname.downcase.include?('1080p')
        g720 = group_name.include?('720p')
        g1080 = group_name.include?('1080p')
        if (r720 && g720) || (r1080 && g1080) || (!r720 && !r1080 && !g720 && !g1080)
          group[:name] = rname
        end
      end
    end

    groups
  end

  def self.print_groups(groups)
    shown_groups = groups.collect do |group|
      files = group[:files]
      "#{group[:name]} (#{files.count} file#{'s' if files.count != 1})"
    end

    if shown_groups.count == 0
      Helper.put_header 'No results.'
      exit
    elsif shown_groups.count == 1
      Helper.put_header 'Single result, proceeding...'
      return 0
    end

    selected = List.list_paginate "Choose a file (nav. using arrows and 'n', 'p') ", shown_groups
    exit if selected == -3
    selected
  end
end

def clear
  system('clear') || system('cls')
end

def axel_download(url, filename)
  download_path = "#{Dir.home}/Downloads/#{filename}"
  system("axel -o \"#{download_path}\" \"#{url}\"")
end

def wget_download(url, filename)
  download_path = "#{Dir.home}/Downloads/#{filename}"
  params = "--continue --no-proxy --timeout 30 -O \"#{download_path}\""
  system("wget \"#{url}\" #{params}")
end

begin
  Helper.put_header "Cargo with #{options[:wget] ? 'Wget' : 'Axel'}"

  if options[:urls]
    text = options[:urls]
    links = LinkScanner.scan_for_ub_links(text)
    puts "Links: \n#{links.join("\n")}"

    groups = Main.groups_from_links(links)

    Helper.put_header
    puts 'Found:'

    groups.each { |group| puts group[:name] }
    groups.each do |group|
      group[:files].each do |file|
        puts "Downloading #{file[:filename]}"
        download_link = UpToBox.get_download_link(file)

        if options[:wget]
          wget_download(download_link, file[:filename])
        else
          axel_download(download_link, file[:filename])
        end
      end
    end
    puts 'Done!'
    exit
  end

  filter = options[:filter]
  releases = Shows.on_demand(filter, options[:movies])
  chosen_release = releases[Main.print_releases(releases)]

  clear

  Helper.put_header "You chose #{chosen_release.first}"

  links, release_names = Shows.releases_for(chosen_release.last)
  groups = Main.groups_from_links(links, release_names)
  chosen_group = groups[Main.print_groups(groups)]

  clear

  Helper.put_header "You chose #{chosen_group[:name]}"

  scripts_count = `ps ax`.scan(%r{/cargo.rb(?:\s|$)}).count
  scripts_count = `ps ax`.scan(/cargo.rb(?:\s|$)/).count if scripts_count == 0

  if scripts_count > 1
    puts 'Waiting for other cargo download to finish...'
    while scripts_count > 1
      sleep(5)
      scripts_count = `ps ax`.scan(%r{/cargo.rb(?:\s|$)}).count
      scripts_count = `ps ax`.scan(/cargo.rb(?:\s|$)/).count if scripts_count == 0
    end
  end

  one_file = chosen_group[:files].count == 1
  chosen_group[:files].each do |file|
    filename = file[:filename]
    filename.gsub!(/.+?(?=\.(?:part|mkv|mp4))/, chosen_group[:name])

    wget = options[:wget]
    download_path = "#{Dir.home}/Downloads/#{filename}"

    file_exists = File.exist?(download_path)
    resume_file_exists = File.exist?("#{download_path}.st")

    if one_file || (file_exists && resume_file_exists) || !file_exists || wget
      download_link = UpToBox.get_download_link(file)

      if wget
        wget_download(download_link, filename)
      else
        axel_download(download_link, filename)
      end
    end
  end

  puts 'Done!'
rescue Interrupt => e
  puts e
end
