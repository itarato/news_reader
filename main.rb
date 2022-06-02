require 'uri'
require 'net/http'
require 'pp'
require 'json'
require 'pry'
require 'cgi'

# Bugs:
# - text indenter `block_indent` can cut non visible escape chars - ruining terminal
#   colors and formatting
# - text generally looks too wide, but cannot make the window narrower too much
# - making terminal narrow ruins the main title listing

# Refactor:
# - context own printing and navigation

# Ideas:
# - async background story load
# - sqlite caching or something
# - html to terminal color converter
# - pager
# - story load all comments
# - list limit sizing (+/- or presets)
# - per context keystroke legend

class Util
  class << self
    def red(s); escape(s, 91); end
    def green(s); escape(s, 92); end
    def yellow(s); escape(s, 93); end
    def blue(s); escape(s, 94); end
    def magenta(s); escape(s, 95); end
    def cyan(s); escape(s, 96); end
    def gray(s); escape(s, 90); end
    def orange(s); escape(s, 208); end
    def bold(s); escape(s, 1); end
    def dim(s); escape(s, 22); end
    def invert(s); escape(s, 7); end
    def console_lines; %x`tput lines`.to_i; end
    def console_cols; %x`tput cols`.to_i; end
    def color(s, fg, bg); escape(s, "#{fg};48;5;#{bg}"); end

    def block_indent(width, indent, s)
      s
        .lines
        .map do |line|
          line
            .chars
            .each_slice(width - indent)
            .map do |slice|
              (' ' * indent) + slice.join
            end
            .join("\n")
        end
        .join("\n")
    end

    private

    def escape(s, color_code); "\x1B[#{color_code}m#{s}\x1B[0m"; end
  end
end

class NetClient
  def call(url)
    uri = URI(url)
    res = Net::HTTP.get_response(uri)

    raise("HTTP error") unless res.is_a?(Net::HTTPSuccess)

    res.body
  end

  def call_json(url)
    JSON.parse(call(url))
  end
end

class Post
  ITEM_URL_PREFIX = 'https://hacker-news.firebaseio.com/v0/item/'

  def initialize(net_client, id)
    @net_client = net_client
    @id = id
    @json_data = json_data
    @kids = {}
  end

  def json_data
    @json_data ||= begin
      @net_client.call_json(ITEM_URL_PREFIX + @id.to_s + ".json")
    end
  end

  def title  = json_data['title']
  def url    = json_data['url']
  def type   = json_data['type']
  def kids   = json_data['kids'] || []
  def score  = json_data['score']
  def text   = json_data['text']
  def parent = json_data['parent']

  def has_kids? = kids && kids.size > 0

  def kid_nth(n)
    raise("Kid #{n} does not exist in #{inspect}") if n >= kids.size
    kid(kids[n])
  end

  def kid(id)
    @kids[id] ||= Post.new(@net_client, id)
  end

  def rich_title
    type_and_score = "[#{type} / #{score}]"
    comments = "#{kids.size} comments"
    "#{Util.bold(title)}\n  #{Util.gray(type_and_score)} #{Util.magenta(comments)}"
  end

  def rich_text_minimal_formatting
    nice_text = text || ''
    nice_text = CGI.unescapeHTML(nice_text)
    nice_text = nice_text.gsub(/<p>/, " ")
    nice_text = nice_text.gsub(/(\[\d+\])/, "\x1B[7m\\1\x1B[27m")
    nice_text = nice_text.gsub(/<i>([^<]+)<\/i>/, "\x1B[1m\\1\x1B[21m")
    nice_text = nice_text.gsub(/<a href="([^"]+)"[^<]+<\/a>/, "\x1B[4m\\1\x1B[24m")
    nice_text
  end

  def rich_text
    reply = "[#{kids.size} reply]"
    nice_text = rich_text_minimal_formatting

    "#{nice_text} #{Util.magenta(reply)}"
  end
end

class Feed
  def initialize(net_client, feed_url)
    @net_client = net_client
    @feed_url = feed_url
    @toplist_ids = nil
    @posts = {}
  end

  def toplist_ids
    @toplist_ids ||= @net_client.call_json(@feed_url)
  end

  def post_nth(n)
    raise("Post number #{n} does not exist") if n >= toplist_ids.size || n < 0
    post(toplist_ids[n])
  end

  def post(id)
    @posts[id] ||= Post.new(@net_client, id)
  end
end

class Feeds
  TOP_STORY_LIST_URL = 'https://hacker-news.firebaseio.com/v0/topstories.json'
  TOP_ASK_LIST_URL = 'https://hacker-news.firebaseio.com/v0/askstories.json'

  attr_reader(:options)

  def initialize(net_client)
    @net_client = net_client
    @options = {
      "Top stories" => TOP_STORY_LIST_URL,
      "Top asks" => TOP_ASK_LIST_URL,
    }

    @feeds = {}
  end

  def feed_count
    @options.size
  end

  def feed_nth(n)
    raise("Invalid feed n: #{n}") if n < 0 || n >= @options.size
    feed(@options.values[n])
  end

  def feed(url)
    @feeds[url] ||= Feed.new(@net_client, url)
  end
end

class NewsReader
  def initialize(net_client)
    @net_client = net_client
    @feeds = nil
  end

  def feeds
    @feeds ||= Feeds.new(@net_client)
  end
end

module NavigationContext
  class Base
    attr_accessor(:parent)

    def initialize
      @parent = nil
    end
  end

  class Feeds < Base
    attr_reader(:feeds)
    attr_reader(:idx)

    def initialize(feeds)
      super()

      @feeds = feeds
      @idx = 0
    end

    def next
      @idx = (@idx + 1) % @feeds.feed_count
    end

    def prev
      @idx = (@idx - 1 + @feeds.feed_count) % @feeds.feed_count
    end

    def open
      Feed.new(self, @feeds.feed_nth(@idx))
    end
  end

  class Feed < Base
    attr_reader(:idx)
    attr_reader(:feed)

    def initialize(parent, feed)
      super()

      @parent = parent
      @idx = 0
      @feed = feed
    end

    def next
      @idx += 1 if @idx < @feed.toplist_ids.size - 1
    end

    def prev
      @idx -= 1 if @idx > 0
    end

    def open
      Post.new(self, selected_post)
    end

    def close
      @parent
    end

    def selected_post
      @feed.post_nth(@idx)
    end

    def post_exist?(n)
      n < @feed.toplist_ids.size
    end
  end

  class Post < Base
    attr_reader(:post)
    attr_reader(:comment_context)

    def initialize(parent, post)
      super()

      @parent = parent
      @post = post
      @comment_context = Comment.new(@post)
    end

    def close
      if @comment_context.parent.nil?
        @parent
      else
        @comment_context = @comment_context.close
        self
      end
    end

    def next
      @comment_context.next
    end

    def prev
      @comment_context.prev
    end

    def open
      @comment_context = @comment_context.open
    end

    def comment_exist?(n)
      n < @comment_context.comment.kids.size
    end
  end

  class Comment < Base
    attr_reader(:idx)
    attr_reader(:comment)

    def initialize(comment, parent = nil)
      super()

      @comment = comment
      @parent = parent
      @idx = 0
    end

    def next
      @idx += 1 if @idx < @comment.kids.size - 1
    end

    def prev
      @idx -= 1 if @idx > 0
    end

    def open
      return self unless current_comment.has_kids?
      Comment.new(current_comment, self)
    end

    def current_comment
      @comment.kid_nth(@idx)
    end

    def close
      @parent
    end

    def ancestors
      return [] if @parent.nil?

      out = [comment]
      current = @parent

      while !current.nil?
        out.unshift(current.comment) unless current.parent.nil?
        current = current.parent
      end

      out
    end
  end
end

class Navigator
  FEED_LIST_SIZE = 8
  COMMENT_LIST_SIZE = 3

  def initialize
    @net_client = NetClient.new
    @news_reader = NewsReader.new(@net_client)
    @context = NavigationContext::Feeds.new(@news_reader.feeds)
  end

  def run
    loop do
      clear_terminal
      print_screen

      key = read_char
      case key
      when 'q' then break
      when 's'
        case @context
        when NavigationContext::Feeds then @context.next
        when NavigationContext::Feed then @context.next
        when NavigationContext::Post then @context.next
        end
      when 'w'
        case @context
        when NavigationContext::Feeds then @context.prev
        when NavigationContext::Feed then @context.prev
        when NavigationContext::Post then @context.prev
        end
      when 'd'
        case @context
        when NavigationContext::Feeds then @context = @context.open
        when NavigationContext::Feed then @context = @context.open
        when NavigationContext::Post then @context.open
        end
      when 'a'
        case @context
        when NavigationContext::Feed then @context = @context.close
        when NavigationContext::Post then @context = @context.close
        end
      end
    end
  end

  def print_screen
    puts(Util.color("   HackerNews Reader | v0.0   ", 97, 208))
    puts()

    case @context
    when NavigationContext::Feeds
      @context.feeds.options.each_with_index do |(name, _), i|
        prefix = i == @context.idx ? Util.yellow('> ') : '  '
        puts("#{prefix}#{name}\n\n")
      end
    when NavigationContext::Feed
      start = @context.idx - (@context.idx % FEED_LIST_SIZE)

      start.upto(start + FEED_LIST_SIZE - 1) do |i|
        break unless @context.post_exist?(i)

        prefix = i == @context.idx ? Util.yellow('> ') : '  '
        puts("#{prefix}#{@context.feed.post_nth(i).rich_title}\n\n")
      end
    else NavigationContext::Post
      console_cols = Util.console_cols

      puts("  #{@context.post.rich_title}")
      puts("\n  #{Util.cyan(@context.post.url)}") if @context.post.url
      puts()

      if @context.post.text
        puts(Util.gray(Util.block_indent(console_cols, 4, @context.post.rich_text_minimal_formatting)))
        puts()
      end

      puts('-' * 32)
      puts()

      ancestors = @context.comment_context.ancestors
      ancestors.each_with_index do |ancestor, i|
        puts(Util.blue(Util.block_indent(console_cols, (i + 1) * 4, ancestor.rich_text)))
        puts()
      end

      puts("#{'- ' * 16}\n\n") if ancestors.size > 0

      comment_start = @context.comment_context.idx - (@context.comment_context.idx % COMMENT_LIST_SIZE)
      comment_start.upto(comment_start + COMMENT_LIST_SIZE - 1) do |i|
        break unless @context.comment_exist?(i)

        prefix = i == @context.comment_context.idx ? '> ' : '  '
        index = Util.gray("#{i})")
        puts("#{Util.yellow(prefix)} #{index} #{@context.comment_context.comment.kid_nth(i).rich_text}\n\n")
      end

      puts(Util.gray("\t#{comment_start}..#{comment_start + COMMENT_LIST_SIZE - 1} out of #{@context.comment_context.comment.kids.size - 1}"))
    end
  end

  def clear_terminal
    print(`clear`)
  end

  def read_char
    system('stty', 'raw', '-echo')
    char = STDIN.getc
    system('stty', '-raw', 'echo')
    char
  end
end

Navigator.new.run
