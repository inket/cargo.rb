require 'open-uri'
require 'net/http'
require 'cgi'
require 'optparse'
require 'date'
require 'inquirer'

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: cargo [options] [filter/urls]"

  opts.on("-m", "--movies", "Show movies in the list") do |v|
    options[:movies] = v
  end

  opts.on("-w", "--wget", "Use 'wget' for the downloads instead of the default 'axel'") do |v|
    options[:wget] = v
    if (options[:wget] && `which wget`.strip == "")
      puts "Wget is not installed. Please install it with \`brew\` and try again."
      exit
    end
  end

  opts.on("-d", "--direct-download", "Download from the provided UpToBox links") do |links|
    options[:urls] = ARGV.join(" ")
  end

  opts.separator ""
  opts.separator "Examples:"
  opts.separator "    cargo detective"
  opts.separator "    cargo -w"
  opts.separator "    cargo -d http://uptobox.com/hrfow01yixy4 http://uptobox.com/hrfow01yixy4"
end.parse!

if (!options[:wget] && `which axel`.strip == "")
  puts "Axel is not installed. Defaulting to wget..."
  options[:wget] = true
  if (`which wget`.strip == "")
    puts "Wget is not installed. Please install it with \`brew\` and try again."
    exit
  end
end

unless (ARGV.empty?)
  options[:filter] = ARGV.join(" ")
end

class PrettyError
  def initialize(message = nil, exception = StandardError.new, full_backtrace = false)
    @message = message
    @exception = exception
    @full_backtrace = full_backtrace
  end

  def to_s
    lines = []
    lines << "*Additional message: "+@message if @message
    lines << "*Error: #{@exception}"

    if (@exception.backtrace)
      if (@full_backtrace)
        lines << "*Backtrace: \n\t"+@exception.backtrace.join("\n\t")
      else
        lines << "*Backtrace: "+@exception.backtrace.first
      end
    end

    "Caught Exception: #{@exception.class} {\n#{lines.join("\n")}\n}"
  end
end

class LinkScanner
  def self.scan_for_ub_links(text)
    text.scan(/http\:\/\/(?:www\.)?uptobox\.com\/[a-z\d]{12}/im).flatten.uniq
  end

  def self.get(links_of_interest)
    begin
      groups = UpToBox.check_urls(links_of_interest) || []

      groups
    rescue StandardError => e
      puts PrettyError.new("Couldn't check the given links.", e, true)
      nil
    end
  end

  def self.scan_and_get(text)
    links = LinkScanner.scan_for_ub_links(text)

    LinkScanner.get(links)
  end
end

class Helper
  # bytes -> human readable size
  def self.human_size(n, base = 8)
    return "0" if n.nil?

    units = ["B", "KB", "MB", "GB"]

    unit = units[0]
    size = n

    if (n.instance_of?String)
      unit = n[-2, 2]
      size = n[0..-2].to_f
    end

    if ((size >= 1024 && base == 8) || (size >= 1000 && base == 10))
      human_size((base==8?(size/1024):(size/1000)).to_s+units[units.index(unit)+1], base)
    else
      if (size == size.to_i)
        return size.to_i.to_s+unit
      else
        index = size.to_s.index(".")

        return size.to_s[0..(index-1)]+unit if units.index(unit) < 2

        begin
          return size.to_s[0..(index+2)]+unit
        rescue
          return size.to_s[0..(index+1)]+unit
        end
      end
    end
  end

  # time -> minimalist date+time
  def self.human_time(time)
    time = Time.at(time.to_i) unless time.kind_of?(Time)
    twelveclock = false

    day = ""
    now = Time.now
    if (time.day != now.day || time.month != now.month || time.year != now.year)
      tmp = now-86400
      is_yesterday = (time.day == tmp.day && time.month == tmp.month && time.year == tmp.year)

      if (is_yesterday)
        day = "yesterday"
      else
        day = time.strftime("%-d %b")
      end
    end

    return day+" "+(twelveclock ? time.strftime("%I:%M%P") : time.strftime("%H:%M"))
  end

  # time -> relative
  def self.relative_time(time)
    time = Time.at(time.to_i) unless time.kind_of?(Time)

    now = Time.now
    diff = now - time
    hours_ago = (diff / 3600).to_i
    minutes_ago = (diff / 60).to_i

    r = nil
    if (hours_ago < 24)
      r = hours_ago > 0 ? "#{hours_ago}h ago" : "#{minutes_ago}m ago"
    else
      r = "#{hours_ago/24}d ago"
    end

    r
  end

  def self.to_bytes(size)
    number = size.to_f
    unit = size.to_s.gsub(/[^a-zA-Z]/, "")

    return number.to_i if unit.empty?

    if (unit.downcase == "k" || unit.downcase == "kb")
      return (number*1024).to_i
    elsif (unit.downcase == "m" || unit.downcase == "mb")
      return (number*1024*1024).to_i
    elsif (unit.downcase == "g" || unit.downcase == "gb")
      return (number*1024*1024*1024).to_i
    else
      return number.to_i
    end
  end

  def self.escape_url(url)
    CGI.escape(url).gsub(" ", "%20").gsub("+", "%20")
  end

  def self.attempt(max_tries)
    return nil if max_tries < 1

    tries = 0
    begin
      yield
    rescue StandardError => e
      tries += 1
      if (tries < max_tries)
        retry
      else
        puts e.to_s
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
      if (tries < max_tries)
        retry
      else
        raise e
      end
    end
  end

  # Kinda like OpenURI's open(url), except it allows to limit fetch size
  # Solution found @ http://stackoverflow.com/a/8597459/528645
  def self.open_uri(url, limit = 102400)
    uri = URI(url)
    result = nil

    require 'socket'

    request = "GET #{uri.path} HTTP/1.1\r\n"
    request += "Host: #{uri.host}\r\n"
    request += "\r\n"

    socket = TCPSocket.open(uri.host, uri.port)
    socket.print(request)

    buffer = ""
    while !buffer.match("\r\n\r\n") do
      buffer += socket.read(1)
    end

    result = socket.read(limit)
    result
  end
end

class UpToBox
  def self.check_urls(urls)
    files = []

    urls.each {
      |url|

      next if url.match(/http\:\/\/(?:www\.)?uptobox\.com\/[a-z\d]{12}/im).nil?

      files << self.check_file(url)
    }

    self.organize(files.compact)
  end

  def self.check_file(url)
    page, dead = nil

    Helper.attempt_and_raise(3) {
      resp = Net::HTTP.get_response(URI(url))
      page = resp.body
      dead = (resp.code.to_i != 200)
    }

    id = url.split("/").last

    if (!dead)
      rand = page.scan(/(?:'|")rand(?:'|") value=(?:'|")(.*?)(?:'|")/mi).flatten.first
      fname = page.scan(/(?:'|")fname(?:'|") value=(?:'|")(.*?)(?:'|")/mi).flatten.first
      size = page.scan(/para_title.*?\(\s*(.*?)\s*\)/im).flatten.first
      cleaner = "?_?))skcor|gro|ten:?(.\\:?(yellavldd?_".reverse
      filename = fname.gsub(/#{cleaner}/im, "")

      noextension = filename.split(".").take(filename.split(".").count-1).join(".")
      if noextension.match(/part\d+$/)
        noextension = noextension.split(".").take(noextension.split(".").count-1).join(".")
      end
    else
      puts "#{url} - Dead link"
      rand, filename, noextension = "DEAD"
      size = "0"
    end

    {
      :url => url,
      :id => id,
      :rand => rand,
      :fname => fname,
      :filename => filename,
      :noextension => noextension,
      :dead => dead,
      :size => Helper.to_bytes(size)
    }
  end

  def self.organize(files)
    # detect multipart files and organize them in groups
    grouped_files = []
    files.each {
      |file|

      if (file[:dead])
        grouped_files << {:name => file[:url], :files => [], :dead => true}
        next
      end

      added = false

      grouped_files.each {
        |group|
        if group[:name] == file[:noextension]
          group[:files] << file
          added = true
          break
        end
      }

      next if added

      new_group_name = (file[:filename] =~ /\.part\d+\.rar$/i) ? file[:noextension] : file[:filename]
      grouped_files << {:name => new_group_name, :files => [file]}
    }

    # calculate total size for each group
    grouped_files.each {
      |group|
      group[:size] = 0
      group[:host] = "UpToBox"

      group[:files].each {
        |file|

        group[:size] += file[:size].to_i
      }

      group[:name] = group[:files].first[:filename] if group[:files].count == 1
    }

    grouped_files
  end

  def self.get_download_link(file, last_time = false)
    return nil if (file.nil? || file[:dead])

    directlink = nil

    Helper.attempt(3) {
      while true
        uri = URI(file[:url])
        http = Net::HTTP.new(uri.host)
        data = "rand=#{file[:rand]}&op=download2&id=#{file[:id]}&referer=&method_free=&method_premium&down_direct=1&fname=#{file[:fname]}"
        result = http.post(uri.path, data, {"Referer" => file[:url]})

        wait_message = result.body.scan(/(You have to wait.*?)<\/font>/i).flatten.first
        wait = !wait_message.nil?

        skipped_countdown = !result.body.scan(/Skipped countdown/i).flatten.first.nil?

        if wait
          puts wait_message
          sleep 60
        elsif skipped_countdown
          puts "Waiting for countdown..."
          sleep 120
        else
          break
        end
      end

      directlink = result.body.scan(/(http:\/\/.{1,10}\.uptobox.com\/d\/.*?)(?:'|")/i).flatten.first

      if (!directlink || !directlink.include?("uptobox.com/d/"))
        raise StandardError.new("Couldn't get direct link for download.")
      end
    }

    if ((directlink.nil? || directlink.empty?) && !last_time)
      puts "Trying again with a new download session..."
      directlink = self.get_download_link(self.check_file(file[:url]), true)
    elsif ((directlink.nil? || directlink.empty?) && last_time)
      puts "Skipping. Servers might be down."
    end

    (directlink.nil? || directlink.empty?) ? nil : directlink
  end

  def self.download(url)
    file = UpToBox.check_file(url)
    return nil if (file.nil? || file[:dead])

    directlink = UpToBox.directlink(file)

    [file[:filename], directlink]
  end
end

class Shows
  @@shows_cache_path = File.join(File.dirname(__FILE__), *%w[../cache/shows])
  @@website = "skcor.yellavldd".reverse # don't attract search engines!
  @@debug = false

  def self.sm_url
    month = Time.now.month.to_s
    month = "0#{month}" if month.length == 1

    "http://www.#{@@website}/sitemap-pt-post-#{Time.now.year.to_s}-#{month}.xml"
  end

  def self.old_sm_url
    month = (Time.now.month-1).to_s
    month = "0#{month}" if month.length == 1

    "http://www.#{@@website}/sitemap-pt-post-#{Time.now.year.to_s}-#{month}.xml"
  end

  def self.check_page_for_relevant_links(source, release_names, page_name, fallback)
    source = source.scan(/<div\sclass=(?:\"|')cont cl(?:\"|')>(.*?)<div\sclass=(?:\"|')bot cl(?:\"|')/im).flatten
    source = source.first.gsub(/\n/, "").gsub(/<br\s?\/?>/, "").strip
    parts = source.split(/<hr\s*?\/?>/im)

    sd_releases = []
    hd_releases = []
    release_names.each {
      |r_name|
      r_name.include?("720p") ? hd_releases << r_name : sd_releases << r_name
    }

    valid_releases = hd_releases # will check the HD releases
    if (hd_releases.empty?) # unless there's no HD releases :(
      if (!fallback) # in that case, we wait for them to be uploaded
        puts "720p version still not uploaded... will check later..." if @@debug
        return nil
      else # unless we already waited A LOT. Then, SD releases will do
        puts "Couldn't find 720p version, falling back to anything else..." if @@debug
        valid_releases = sd_releases
      end
    end

    groups = nil
    chosen_release = nil
    valid_releases.each {
      |release|

      # Get the part of the page that has the release we want and its links
      relevant_part = parts[release_names.index(release)]
      if (!relevant_part || !relevant_part.include?(release))
        parts.each {
          |part|
          relevant_part = part if part.include?(release)
        }
      end

      # process the 1-click links and the multiparts alone
      mirrors = [relevant_part.gsub(/info3.*/im, ""), relevant_part.gsub(/.*info3/im, "")]

      mirrors.each {
        |mirror|
        # Scan the links
        groups = catch(:groups) {
          links = LinkScanner.scan_for_ub_links(mirror)
          groups = LinkScanner.get(links)
          throw(:groups, groups) unless links.empty? || groups.first[:dead]

          throw(:groups)
        }

        break if groups # no need to check the multi-part links cause we got the 1-click one
      }

      chosen_release = release
      break if groups
    }

    if groups.nil? || groups.empty?
      puts "No valid links found for #{page_name}."
      return nil
    end

    best_group = groups.first
    groups.each {
      |group|
      best_group = group if group[:size] > best_group[:size]
    }

    {
      :files => best_group[:files],
      :name => chosen_release,
      :reference => page_name,
      :host => best_group[:host]
    }
  end

  def self.check_page_for_release_names(source, show_looking_for, expected_release)
    first_release_name = source.scan(/<h1>(.*?)<\/h1>/im).flatten.first
    first_release_name = first_release_name.split("&#038;").first if first_release_name

    source = source.scan(/<div\sclass=(?:\"|')cont cl(?:\"|')>(.*?)<div\sclass=(?:\"|')bot cl(?:\"|')/im).flatten
    raise StandardError.new("Couldn't find release info") if source.empty?

    # US release naming convention: show.name.S01E01
    us_regex = /.*[\.\s]S\d\dE\d\d.*/i
    # UK release naming convention: show_name.1x01
    uk_regex = /[\.\s]\d\d?.{1,2}\d\d.*/i
    # Other release naming conventions, e.g. show.name.yyyy.mm.dd
    other_regex =  Regexp.new("^"+show_looking_for.gsub(/\./, "[\\.\\s]")+"[\\.\\s].*", true)

    source = source.first.gsub(/\n/, "").strip
    bolded_parts = source.scan(/<strong>(.*?)<\/strong>/).flatten
    release_names = [first_release_name]

    bolded_parts.each {
      |part|

      part.strip.split(/<br\s?\/?>/im).each {
        |p|
        release_names << p.scan(us_regex)
        release_names << p.scan(uk_regex)
        release_names << p.scan(other_regex)
      }
    }

    release_names = release_names.flatten.uniq.compact

    release_names
  end

  def self.on_demand(reference = nil, filter = nil, show_movies = false)
    result = []

    if (reference.nil?)
      sitemap = open(self.sm_url).read.to_s
      releases = sitemap.scan(/<loc>(http\:\/\/(?:www\.)?#{@@website.gsub(".", "\\.")}\/([^<]+?))\/<\/loc>.*?<lastmod>(.*?)<\/lastmod>/im).uniq

      sitemap = open(self.old_sm_url).read.to_s
      releases = releases + sitemap.scan(/<loc>(http\:\/\/(?:www\.)?#{@@website.gsub(".", "\\.")}\/([^<]+?))\/<\/loc>.*?<lastmod>(.*?)<\/lastmod>/im).uniq

      # only keep shows in the array if not specified
      unless show_movies
        us_regex = /-S\d{2}(E\d{2}){1,2}-/i
        uk_regex = /-\d{1,2}x\d{2}-/i
        other_regex = /-\d{4}-\d{2}-\d{2}-/i
        releases = releases.collect {
          |release|
          rname = release[1]
          release if (rname =~ us_regex) || (rname =~ uk_regex) || (rname =~ other_regex)
        }.compact.take(200)
      end

      releases.each {
        |url, release_name, lastmod|

        formatted_name = release_name.gsub(/-|_|\./, " ")

        parts = formatted_name.split(" ").compact

        parts = parts.collect {
          |word|
          word = word.capitalize unless ["and", "of", "with", "in", "x264"].include?(word)
          word = word.upcase if ["au", "us", "uk", "ca", "hdtv", "xvid", "pdtv", "web", "dl"].include?(word.downcase)
          word = word.upcase if word =~ /s\d{2}e\d{2}/i
          word
        }

        parts << parts.pop.upcase unless parts.empty?

        formatted_name = parts.join(" ")

        if (filter.nil? || (filter && formatted_name.downcase.include?(filter.downcase)))
          result << ["(#{Helper.relative_time(DateTime.parse(lastmod).to_time)}) #{formatted_name}", release_name]
        end
      }
    else
      source = (open "http://#{@@website}/#{CGI.escape(reference)}").read.to_s

      # remove sections that contain multipart links because we have better one-click links
      source = source.gsub(/info3.*?info2/im, "")

      result = LinkScanner.scan_for_ub_links(source)
    end

    result
  end
end

class List
  def run clear, response
    # finish if there's nothing to do
    return nil if Array(@elements).empty?

    get_next = false
    get_prev = false
    quit = false

    # hides the cursor while prompting
    IOHelper.without_cursor do
      # render the
      IOHelper.render( update_prompt )
      # loop through user input
      IOHelper.read_key_while do |key|
        @pos = (@pos - 1) % @elements.length if key == "up"
        @pos = (@pos + 1) % @elements.length if key == "down"
        get_next = (key == "down" && @pos == 0) || (key == "right")
        get_prev = (key == "up" && @pos == 0) || (key == "left")

        IOHelper.rerender( update_prompt )
        # we are done if the user hits return

        quit = key == "q"
        get_next = get_next || (key == "n")
        get_prev = get_prev || (key == "p")

        key != "return" && !quit && !get_next && !get_prev
      end
    end

    # clear the final prompt and the line
    IOHelper.clear if clear

    # show the answer
    IOHelper.render( update_response ) if response && !get_next && !get_prev

    # return the index of the selected item
    return -1 if get_next
    return -2 if get_prev
    return -3 if quit
    @pos
  end

  def self.list_paginate *args
    List.ask_paginate *args
  end

  def self.ask_paginate question = nil, elements = [], opts = {}
    l = List.new question, elements, opts[:renderer], opts[:rendererResponse]

    l.all_elements = elements
    l.page = 1
    selected = -3

    loop do
      selected = l.run opts.fetch(:clear, true), opts.fetch(:response, true)
      if selected == -1
        l.page = l.page+1 if l.page < l.pages_count
      elsif selected == -2
        l.page = l.page-1 if l.page > 1
      else
        break
      end
    end

    selected != -3 ? selected+l.offset : selected
  end

  def all_elements=(el)
    @all_elements = el
  end

  def elements=(el)
    @elements = el
  end

  def page
    @page
  end

  def page=(p)
    @page = p
    @elements = self.current_page_elements
  end

  def pages_count
    (@all_elements.count/self.elements_per_page).ceil
  end

  def offset
    (@page-1)*self.elements_per_page
  end

  def elements_per_page
    20
  end

  def current_page_elements
    @all_elements[(self.offset)..-1].take(self.elements_per_page)
  end

  def update_prompt
    # transform the list into
    # {"value"=>..., "selected"=> true|false}
    e = @elements.
      # attach the array position
      map.with_index(0).
      map do |c,pos|
        { "value"=>c, "selected" => pos == @pos }
      end
    # call the renderer
    q = @question
    q = q + " (page #{@page})" if @page && self.pages_count > 1
    @prompt = @renderer.render(q, e)
  end
end

class Main
  def self.print_releases(releases)
    shown_releases = releases.collect { |r| r.first }

    if (shown_releases.count == 0)
      puts "No results."
      puts "----------------------------------------------------"
      exit
    elsif (shown_releases.count == 1)
      puts "Single result, proceeding..."
      puts "----------------------------------------------------"
      return 0
    end

    selected = List.list_paginate "Choose a release (nav. using arrows and 'n', 'p') ", shown_releases
    exit if selected == -3
    selected
  end

  def self.groups_from_links(links)
    if (links.empty? || links.nil?)
      puts "No links"
      exit
    end
    groups = LinkScanner.get(links)
    if (groups.nil?)
      puts "No groups"
      exit
    end

    groups
  end

  def self.print_groups(groups)
    shown_groups = groups.collect {
      |group|
      files = group[:files]
      "#{group[:name]} (#{files.count} file#{'s' if files.count != 1})"
    }

    if (shown_groups.count == 0)
      puts "No results."
      puts "----------------------------------------------------"
      exit
    elsif (shown_groups.count == 1)
      puts "Single result, proceeding..."
      puts "----------------------------------------------------"
      return 0
    end

    selected = List.list_paginate "Choose a file (nav. using arrows and 'n', 'p') ", shown_groups
    exit if selected == -3
    selected
  end
end

def clear
  system("clear") or system("cls")
end

def axel_download(url, filename)
  system("axel -o \"#{Dir.home}/Downloads/#{filename}\" \"#{url}\"")
end

def wget_download(url, filename)
  system("wget \"#{url}\" --continue --no-proxy --timeout 30 -O \"#{Dir.home}/Downloads/#{filename}\"")
end

begin
  puts "Cargo with #{options[:wget] ? 'Wget' : 'Axel'}"
  puts "----------------------------------------------------"

  if (options[:urls])
    text = options[:urls]
    links = LinkScanner.scan_for_ub_links(text)
    puts "Links: \n#{links.join("\n")}"

    groups = Main.groups_from_links(links)
    puts "----------------------------------------------------"
    puts "Found:"
    groups.each {
      |group|
      puts group[:name]
    }
    groups.each {
      |group|
      group[:files].each {
        |file|
        puts "Downloading #{file[:filename]}"
        download_link = UpToBox.get_download_link(file)

        if (options[:wget])
          wget_download(download_link, file[:filename])
        else
          axel_download(download_link, file[:filename])
        end
      }
    }
    puts "Done!"
    exit
  end

  filter = options[:filter]
  releases_offset = 0
  releases = Shows.on_demand(nil, filter, options[:movies])
  chosen_release = releases[Main.print_releases(releases)]

  clear

  puts "You chose #{chosen_release.first}"
  puts "----------------------------------------------------"

  links = Shows.on_demand(chosen_release.last)
  groups = Main.groups_from_links(links)
  chosen_group = groups[Main.print_groups(groups)]

  clear

  puts "You chose #{chosen_group[:name]}"
  puts "----------------------------------------------------"

  scripts_count = `ps ax`.scan(/\/cargo.rb(?:\s|$)/).count
  scripts_count = `ps ax`.scan(/cargo.rb(?:\s|$)/).count if scripts_count == 0

  if scripts_count > 1
    puts "Waiting for other cargo download to finish..."
    while scripts_count > 1
      sleep(5)
      scripts_count = `ps ax`.scan(/\/cargo.rb(?:\s|$)/).count
      scripts_count = `ps ax`.scan(/cargo.rb(?:\s|$)/).count if scripts_count == 0
    end
  end

  chosen_group[:files].each {
    |file|
    download_link = UpToBox.get_download_link(file)

    if (options[:wget])
      wget_download(download_link, file[:filename])
    else
      axel_download(download_link, file[:filename])
    end
  }

  puts "Done!"
rescue Interrupt => e
  puts e
end
