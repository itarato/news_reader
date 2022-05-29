require 'uri'
require 'net/http'
require 'pp'
require 'json'
require 'pry'

# Refactor:
# - context own printing and navigation

# Ideas:
# - async background story load
# - html to terminal color converter
# - pager
# - story load all comments
# - list limit sizing (+/- or presets)

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
        .chars
        .each_slice(width - indent)
        .map do |slice|
          (' ' * indent) + slice.join
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
    "#{Util.bold(title)} #{Util.gray(type_and_score)} #{Util.magenta(comments)}"
  end

  def rich_text
    reply = "[#{kids.size} reply]"
    "#{text} #{Util.magenta(reply)}"
  end
end

class Feed
  TOP_STORY_LIST_URL = 'https://hacker-news.firebaseio.com/v0/topstories.json'
  TOP_ASK_LIST_URL = 'https://hacker-news.firebaseio.com/v0/askstories.json'

  def initialize(net_client)
    @net_client = net_client
    @toplist_ids = nil
    @posts = {}
  end

  def toplist_ids
    @toplist_ids ||= @net_client.call_json(TOP_STORY_LIST_URL)
  end

  def post_nth(n)
    raise("Post number #{n} does not exist") if n >= toplist_ids.size || n < 0
    post(toplist_ids[n])
  end

  def post(id)
    @posts[id] ||= Post.new(@net_client, id)
  end
end

class NewsReader
  def initialize(net_client)
    @net_client = net_client
    @feed = nil
  end

  def feed
    @feed ||= Feed.new(@net_client)
  end
end

module NavigationContext
  class Base
    attr_accessor(:parent)

    def initialize
      @parent = nil
    end
  end

  class Feed < Base
    attr_accessor(:idx)

    def initialize(feed)
      super()

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

    def into_reply
      @comment_context = @comment_context.into_reply
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

    def into_reply
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
  FEED_LIST_SIZE = 4
  COMMENT_LIST_SIZE = 4

  def initialize
    @net_client = NetClient.new
    @news_reader = NewsReader.new(@net_client)
    @context = NavigationContext::Feed.new(@news_reader.feed)
  end

  def run
    loop do
      clear_terminal
      print_screen

      key = read_char
      case key
      when 'q' then break
      when 's'
        if @context.is_a?(NavigationContext::Feed)
          @context.next
        elsif @context.is_a?(NavigationContext::Post)
          @context.next
        end
      when 'w'
        if @context.is_a?(NavigationContext::Feed)
          @context.prev
        elsif @context.is_a?(NavigationContext::Post)
          @context.prev
        end
      when 'd'
        if @context.is_a?(NavigationContext::Feed)
          @context = @context.open
        elsif @context.is_a?(NavigationContext::Post)
          @context.into_reply
        end
      when 'a'
        @context = @context.close if @context.is_a?(NavigationContext::Post)
      end
    end
  end

  def print_screen
    puts(Util.color("   HackerNews Reader | v0.0   ", 97, 208))
    puts()

    case @context
    when NavigationContext::Feed
      start = @context.idx - (@context.idx % FEED_LIST_SIZE)

      start.upto(start + FEED_LIST_SIZE - 1) do |i|
        break unless @context.post_exist?(i)

        prefix = i == @context.idx ? Util.yellow('> ') : '  '
        puts("#{prefix}#{@news_reader.feed.post_nth(i).rich_title}")
      end
    else NavigationContext::Post
      puts("#{@context.post.rich_title}")
      puts("#{Util.cyan(@context.post.url)}") if @context.post.url
      puts()
      puts('-' * 32)
      puts()

      console_cols = Util.console_cols

      ancestors = @context.comment_context.ancestors
      ancestors.each_with_index do |ancestor, i|
        puts(Util.block_indent(console_cols - 1, (i + 1) * 4, ancestor.rich_text))
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

      puts(Util.gray("\t#{comment_start} .. #{comment_start + COMMENT_LIST_SIZE - 1} out of #{@context.comment_context.comment.kids.size}"))
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
