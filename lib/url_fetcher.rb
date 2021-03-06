require "net/http"
require "openssl"
require "addressable/uri"
require "tempfile"
require "url_fetcher/errors"

# This class will fetch the contents of a URL and store them in a Tempfile. The
# results are exposed as a stream so you don't need to read potentialy huge responses
# into memory all at once.
class UrlFetcher
  MEGABYTE = 1048576
  MAX_ATTEMPTS = 5.freeze

  attr_reader :url, :resolved_url

  # Create a fetcher for the specified URL.
  #
  # Options include (default in parentheses):
  # * :unlink (true) - Automatically delete the Tempfile. The stream will still be open, but will not be accessible from any other process.
  # * :follow_redirects (true) - Automatically follow redirects instead of returning the redirect response.
  # * :method (:get) - HTTP method to use to fetch the URL.
  # * :max_size (10 megabytes)- The maximum size in bytes that should be fetched.
  # * :open_timeout (10) - Time in seconds to wait for a connection to be established.
  # * :read_timeout (20) - Time in seconds to wait for reading the HTTP response.
  # * :headers ("Accept" => "*")- Hash of headers to send with request.
  def initialize(url, options = {}, &redirect_hook)
    @url = url
    @redirect_hook = redirect_hook
    options = default_options.merge(options)
    @response = fetch_response(@url, options)
  end

  # Return a stream to the downloaded URL.
  def body
    @response.body if success?
  end

  def close
    body.close if body && !body.closed?
  end

  def closed?
    body.closed? if body
  end

  # Get the header with the specified name from the response.
  def header(name)
    @response[name]
  end

  # Return true if the response was a redirect (i.e. the redirect_block passed in the header returned false on a redirect)
  def redirect?
    @response.is_a? Net::HTTPRedirection
  end

  # Return true of the the response was a success.
  def success?
    @response.is_a? Net::HTTPSuccess
  end

  private

  def default_options
     { :unlink => true, :follow_redirects => true, :method => :get }
  end

  def fetch_response(url, options, previous_attempts = [])
    if previous_attempts.size > MAX_ATTEMPTS
      raise TooManyRedirects.new(previous_attempts.first, MAX_ATTEMPTS)
    end

    if previous_attempts.include?(url)
      raise CircularRedirect.new(previous_attempts.first)
    end

    previous_attempts << url
    uri = Addressable::URI.parse(url)
    raise Addressable::URI::InvalidURIError.new(url) unless uri
    @resolved_url = uri.to_s

    http = Net::HTTP.new(uri.host, uri.port || uri.inferred_port)
    http.read_timeout = options[:read_timeout] || 20 # This is seconds. Default is 60.
    http.open_timeout = options[:open_timeout] || 10
    if uri.scheme == "https"
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    request = case options[:method]
    when :head
      Net::HTTP::Head.new(uri.request_uri)
    when :post
      Net::HTTP::Post.new(uri.request_uri)
    else
      Net::HTTP::Get.new(uri.request_uri)
    end

    if options[:headers]
      options[:headers].each do |name, value|
        name = name.to_s
        values = Array(value)
        request[name] = values[0].to_s
        values[1, values.length].each do |val|
          request.add_field(name, val.to_s)
        end
      end
    end

    response = http.request(request) do |resp|
      unless resp.is_a?(Net::HTTPSuccess) || resp.is_a?(Net::HTTPRedirection)
        resp.value # Raises an appropriate HTTP error
      end
      if resp.is_a?(Net::HTTPSuccess) && resp.class.body_permitted?
        content_length = resp["Content-Length"].to_i
        raise FileTooBig.new(content_length) if content_length > (options[:max_size] || 10 * MEGABYTE)
        ext = File.extname(url.sub(/\?.*/, ''))
        ext = nil if ext && ext.size > 12
        tempfile = Tempfile.new(["url_fetcher", ext], :encoding => 'ascii-8bit')
        resp.read_body(tempfile)
        tempfile.rewind
      end
    end

    if response.is_a?(Net::HTTPRedirection) && options[:follow_redirects]
      location = response["Location"]
      unless location.include?(':')
        location = Addressable::URI.parse(location)
        location.scheme = uri.scheme
        location.host = uri.host
      end
      abort_redirect = (@redirect_hook ? @redirect_hook.call(location.to_s) == false : false)
      response = fetch_response(location, options, previous_attempts) unless abort_redirect
    end

    response
  end
end
