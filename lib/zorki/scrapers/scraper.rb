# frozen_string_literal: true

require "capybara/dsl"
require "dotenv/load"
require "oj"
require "selenium-webdriver"
require "logger"
require "securerandom"
require "selenium/webdriver/remote/http/curb"
require "debug"

module JSON
  class << self
    alias_method :original_parse, :parse
    def parse(source, opts = {})
      original_parse(source, opts)
    rescue JSON::ParserError => e
      raise unless e.message.include?("surrogate")

      sanitized = source.gsub(/\\u[dD][89a-fA-F][0-9a-fA-F]{2}/, "\\uFFFD")
      original_parse(sanitized, opts)
    end
  end
end

# 2022-06-07 14:15:23 WARN Selenium [DEPRECATION] [:browser_options] :options as a parameter for driver initialization is deprecated. Use :capabilities with an Array of value capabilities/options if necessary instead.

options = Selenium::WebDriver::Options.chrome(exclude_switches: ["enable-automation"])
options.add_argument("--start-maximized")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
options.add_argument("–-disable-blink-features=AutomationControlled")
options.add_argument("--disable-extensions")
options.add_argument("--enable-features=NetworkService,NetworkServiceInProcess")
options.add_argument("user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 13_3_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/113.0.0.0 Safari/537.36")
options.add_preference "password_manager_enabled", false
options.add_argument("--user-data-dir=/tmp/tarun_zorki_#{SecureRandom.uuid}")

Capybara.register_driver :selenium_zorki do |app|
  client = Selenium::WebDriver::Remote::Http::Curb.new
  # client.read_timeout = 60  # Don't wait 60 seconds to return Net::ReadTimeoutError. We'll retry through Hypatia after 10 seconds
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options, http_client: client)
end
Capybara.threadsafe = true
Capybara.default_max_wait_time = 60
Capybara.reuse_server = true

module Zorki
  class Scraper # rubocop:disable Metrics/ClassLength
    include Capybara::DSL

    @@logger = Logger.new(STDOUT)
    @@logger.level = Logger::WARN
    @@logger.datetime_format = "%Y-%m-%d %H:%M:%S"
    @@session_id = nil

    def initialize
      Capybara.default_driver = :selenium_zorki
    end

    # Instagram uses GraphQL (like most of Facebook I think), and returns an object that actually
    # is used to seed the page. We can just parse this for most things.
    #
    # additional_search_params is a comma seperated keys
    # example: `data,xdt_api__v1__media__shortcode__web_info,items`
    #
    # NOTE: `post_data_include` if not nil overrules the additional_search_parameters
    # This is so that i didn't have to refactor the entire code base when I added it.
    # Eventually it might be better to look at the post request and see if we can do the
    # same type of search there as we use for users and simplify this whole thing a lot.
    #
    # @returns Hash a ruby hash of the JSON data
    def get_content_of_subpage_from_url(url, subpage_search, additional_search_parameters = nil, post_data_include: nil, header: nil)
      # Our user data no longer lives in the graphql object passed initially with the page.
      # Instead it comes in as part of a subsequent call. We inject JavaScript to capture
      # fetch/XHR responses, avoiding the selenium-devtools CDP version dependency entirely.
      response_body = nil
      script_id = nil

      # Inject a JS interceptor that runs before any page scripts via CDP.
      # This uses execute_cdp which goes through ChromeDriver directly,
      # bypassing the selenium-devtools gem and its version checks.
      begin
        interceptor_js = <<~JS
          window.__zorki_responses = [];

          (function() {
            var origFetch = window.fetch;
            window.fetch = function(input, init) {
              return origFetch.apply(this, arguments).then(function(response) {
                try {
                  var clone = response.clone();
                  var reqUrl = typeof input === 'string' ? input : (input instanceof Request ? input.url : String(input));
                  var requestHeaders = {};
                  if (input instanceof Request) {
                    input.headers.forEach(function(value, key) { requestHeaders[key] = value; });
                  }
                  if (init && init.headers) {
                    if (init.headers instanceof Headers) {
                      init.headers.forEach(function(value, key) { requestHeaders[key] = value; });
                    } else if (typeof init.headers === 'object') {
                      var entries = Object.entries(init.headers);
                      for (var i = 0; i < entries.length; i++) {
                        requestHeaders[entries[i][0]] = String(entries[i][1]);
                      }
                    }
                  }
                  var postData = null;
                  if (init && init.body) {
                    if (typeof init.body === 'string') { postData = init.body; }
                    else if (init.body instanceof URLSearchParams) { postData = init.body.toString(); }
                  }
                  clone.text().then(function(body) {
                    window.__zorki_responses.push({
                      url: reqUrl,
                      body: body,
                      post_data: postData,
                      request_headers: requestHeaders
                    });
                  });
                } catch(e) {}
                return response;
              });
            };

            var origXHROpen = XMLHttpRequest.prototype.open;
            var origXHRSend = XMLHttpRequest.prototype.send;
            var origXHRSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;

            XMLHttpRequest.prototype.open = function(method, url) {
              this.__zorki_url = typeof url === 'string' ? url : String(url);
              this.__zorki_headers = {};
              return origXHROpen.apply(this, arguments);
            };

            XMLHttpRequest.prototype.setRequestHeader = function(key, value) {
              if (this.__zorki_headers) this.__zorki_headers[key] = value;
              return origXHRSetRequestHeader.apply(this, arguments);
            };

            XMLHttpRequest.prototype.send = function(body) {
              var self = this;
              var postData = body ? String(body) : null;
              this.addEventListener('load', function() {
                try {
                  window.__zorki_responses.push({
                    url: self.__zorki_url,
                    body: self.responseText,
                    post_data: postData,
                    request_headers: self.__zorki_headers || {}
                  });
                } catch(e) {}
              });
              return origXHRSend.apply(this, arguments);
            };
          })();
        JS

        result = page.driver.browser.execute_cdp('Page.addScriptToEvaluateOnNewDocument', source: interceptor_js)
        script_id = result['identifier']
      rescue StandardError => e
        puts "Warning: Could not inject network interceptor: #{e.message}"
      end

      # Now visit the page — the injected script will capture API responses
      page.driver.browser.navigate.to(url)
      dismiss_cookie_consent

      # We'll often get multiple modals and need to dismiss them all...
      dismiss_modal
      dismiss_modal
      dismiss_modal

      # Poll for the matching intercepted response (up to 60 seconds)
      start_time = Time.now
      while response_body.nil? && (Time.now - start_time) < 60
        begin
          responses = page.driver.browser.execute_script('return window.__zorki_responses || []')

          responses.each do |resp|
            next unless resp['url']&.include?(subpage_search)

            if !header.nil?
              header_key = header.keys.first.to_s
              header_value = header.values.first
              req_headers = resp['request_headers'] || {}
              matching = req_headers.find { |k, _v| k.casecmp(header_key).zero? }
              next unless matching && matching[1] == header_value
            elsif !post_data_include.nil?
              next unless resp['post_data']&.include?(post_data_include)
              begin
                JSON.parse(resp['post_data'])
              rescue JSON::ParserError
                next
              end
            end

            next if resp['body'].nil? || resp['body'].empty?

            check_passed = true
            unless additional_search_parameters.nil?
              body_to_check = Oj.load(resp['body'])

              search_parameters = additional_search_parameters.split(",")
              search_parameters.each do |key|
                if body_to_check.nil? || !body_to_check.is_a?(Hash)
                  check_passed = false
                  break
                end

                check_passed = false unless body_to_check.has_key?(key)
                body_to_check = body_to_check[key]
              end
            end

            next unless check_passed
            response_body = resp['body']
            break
          end
        rescue StandardError
          # Page might still be loading, keep polling
        end

        sleep(0.1) if response_body.nil?
      end

      page.driver.execute_script("window.stop();")

      raise ContentUnavailableError.new("Response body nil") if response_body.nil?

      Oj.load(response_body)
    ensure
      if script_id
        begin
          page.driver.browser.execute_cdp('Page.removeScriptToEvaluateOnNewDocument', identifier: script_id)
        rescue StandardError; end
      end
    end

  private

    ##########
    # Set the session to use a new user folder in the options!
    # #####################
    def reset_selenium
      options = Selenium::WebDriver::Options.chrome(exclude_switches: ["enable-automation"])
      options.add_argument("--start-maximized")
      options.add_argument("--no-sandbox")
      options.add_argument("--disable-dev-shm-usage")
      options.add_argument("–-disable-blink-features=AutomationControlled")
      options.add_argument("--disable-extensions")
      options.add_argument("--enable-features=NetworkService,NetworkServiceInProcess")

      options.add_argument("user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 13_3_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/113.0.0.0 Safari/537.36")
      options.add_preference "password_manager_enabled", false
      options.add_argument("--user-data-dir=/tmp/tarun_zorki_#{SecureRandom.uuid}")
      # options.add_argument("--user-data-dir=/tmp/tarun")

      Capybara.register_driver :selenium do |app|
        client = Selenium::WebDriver::Remote::Http::Curb.new
        # client.read_timeout = 60  # Don't wait 60 seconds to return Net::ReadTimeoutError. We'll retry through Hypatia after 10 seconds
        Capybara::Selenium::Driver.new(app, browser: :chrome, options: options, http_client: client)
      end

      Capybara.current_driver = :selenium
    end

    def check_for_login
      xpath_login = '//form[@id="loginForm"]/div/div[3]/button | //input[@type="password"]'
      return true if page.has_xpath?(xpath_login, wait: 2)
      # Occasionally we'll be on a weird page instead of login, so we'll click the login button
      begin
        dismiss_cookie_consent
        dismiss_modal
        login_button = page.all(:xpath, "//div[text()='Log in'] | //a[text()='Log In']", wait: 5).last
        login_button.click unless login_button.nil?

        sleep(5)
        return true if page.has_xpath?(xpath_login, wait: 2)
      rescue Capybara::ElementNotFound; end
      false
    end

    def dismiss_cookie_consent
      puts "looking for cookie accept modal"
      find_button("Allow all cookies", wait: 10).click()
      puts "accepting cookies"
    rescue Capybara::ElementNotFound
      puts "no cookie warning"
      # No cookie consent modal shown, continue
    end

    def dismiss_modal
      puts "looking for modal"
      # Try "Not Now" button (e.g. notifications prompt)
      not_now = page.all(:xpath, '//button[text()="Not Now" or text()="Not now"]', wait: 3).first
      if not_now
        not_now.click
        puts "dismissed modal with 'Not Now'"
        return
      end

      # Try close button
      modal_close = page.all(:xpath, '//*[@aria-label="Close"]', wait: 3).last
      modal_close.click unless modal_close.nil?
      puts "closed modal"
    rescue Capybara::ElementNotFound, Selenium::WebDriver::Error::ElementClickInterceptedError
      puts "modal not found or not clickable"
      # No modal found or couldn't click, continue
    end

    def login(url = "https://instagram.com")
      load_saved_cookies
      # Reset the sessions so that there's nothing laying around
      # page.driver.browser.close

      # Check if we're on a Instagram page already, if not visit it.

      page.driver.browser.navigate.to(url)
      unless page.driver.browser.current_url.include? "instagram.com"
        # There seems to be a bug in the Linux ARM64 version of chromedriver where this will properly
        # navigate but then timeout, crashing it all up. So instead we check and raise the error when
        # that then fails again.
        # page.driver.browser.navigate.to("https://instagram.com")
      end

      # We don't have to login if we already are
      begin
        unless page.find(:xpath, "//span[text()='Profile']", wait: 2).nil?
          return
        end
      rescue Capybara::ElementNotFound; end

      # Check if we're redirected to a login page, if we aren't we're already logged in
      return unless check_for_login

      # Try to log in
      loop_count = 0
      while loop_count < 5 do
        puts "Attempting to fill login field ##{loop_count}"

        username_field = page.all(:xpath, '//input[@name="username" or @name="email" or @type="text" or @type="email"]').first
        raise "Couldn't find username field" if username_field.nil?
        username_field.click
        username_field.send_keys([:control, "a"], :backspace)
        username_field.send_keys(ENV["INSTAGRAM_USER_NAME"])

        password_field = find(:xpath, '//input[@type="password"]')
        password_field.click
        password_field.send_keys([:control, "a"], :backspace)
        password_field.send_keys(ENV["INSTAGRAM_PASSWORD"])

        dismiss_cookie_consent

        # Submit the login form via the hidden input[type=submit]
        sleep(1)
        page.execute_script('document.querySelector("#login_form input[type=submit]").click()')
        sleep(3)

        unless has_css?('p[data-testid="login-error-message"', wait: 3)
          save_cookies
          break
        end
        loop_count += 1
        random_length = rand(1...2)
        puts "Sleeping for #{random_length} seconds"
        sleep(random_length)
      end

      # Sometimes Instagram just... doesn't let you log in
      raise "Instagram not accessible" if loop_count == 5

      # No we don't want to save our login credentials
      begin
        puts "Checking and clearing Save Info button"
        find_button("Save Info", wait: 2).click()
      rescue Capybara::ElementNotFound; end

    end

    def fetch_image(url)
      request = Typhoeus::Request.new(url, followlocation: true)
      request.on_complete do |response|
        if request.success?
          return request.body
        elsif request.timed_out?
          raise Zorki::Error("Fetching image at #{url} timed out")
        else
          raise Zorki::Error("Fetching image at #{url} returned non-successful HTTP server response #{request.code}")
        end
      end
    end

    # Convert a string to an integer
    def number_string_to_integer(number_string)
      # First we have to remove any commas in the number or else it all breaks
      number_string = number_string.delete(",")
      # Is the last digit not a number? If so, we're going to have to multiply it by some multiplier
      should_expand = /[0-9]/.match(number_string[-1, 1]).nil?

      # Get the last index and remove the letter at the end if we should expand
      last_index = should_expand ? number_string.length - 1 : number_string.length
      number = number_string[0, last_index].to_f
      multiplier = 1
      # Determine the multiplier depending on the letter indicated
      case number_string[-1, 1]
      when "m"
        multiplier = 1_000_000
      end

      # Multiply everything and insure we get an integer back
      (number * multiplier).to_i
    end

    # def reset_window
    #   old_handle = page.driver.browser.window_handle
    #   page.driver.browser.switch_to.new_window(:window)
    #   new_handle = page.driver.browser.window_handle
    #   page.driver.browser.switch_to.window(old_handle)
    #   page.driver.browser.close
    #   page.driver.browser.switch_to.window(new_handle)
    # end

    def save_cookies
      cookies_json = page.driver.browser.manage.all_cookies.to_json
      File.write("./zorki_cookies.json", cookies_json)
    end

    def load_saved_cookies
      return unless File.exist?("./zorki_cookies.json")
      page.driver.browser.navigate.to("https://instagram.com")

      cookies_json = File.read("./zorki_cookies.json")
      cookies = JSON.parse(cookies_json, symbolize_names: true)
      cookies.each do |cookie|
        cookie[:expires] = Time.parse(cookie[:expires]) unless cookie[:expires].nil?
        begin
          page.driver.browser.manage.add_cookie(cookie)
        rescue StandardError
        end
      end
    end
  end
end

require_relative "post_scraper"
require_relative "user_scraper"
