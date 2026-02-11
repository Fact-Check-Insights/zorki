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
      # So this is fun:
      # For pages marked as misinformation we have to use one method (interception of requrest) and
      # for pages that are not, we can just pull the data straight from the page.
      #
      # How do we figure out which is which?... for now we'll just run through both and see where we
      # go with it.

      # Our user data no longer lives in the graphql object passed initially with the page.
      # Instead it comes in as part of a subsequent call. This intercepts all calls, checks if it's
      # the one we want, and then moves on.
      response_body = nil

      page.driver.browser.intercept do |request, &continue|
        # This passes the request forward unmodified, since we only care about the response
        continue.call(request) && next unless request.url.include?(subpage_search)
        if !header.nil?
          header_key = header.keys.first.to_s
          header_value = header.values.first

          # puts "Request Header included? #{request.headers.include?(header_key)} #{request.headers[header_key]} == #{header_value}"
          continue.call(request) && next unless request.headers.include?(header_key) && request.headers[header_key] == header_value

        elsif !post_data_include.nil?
          continue.call(request) && next unless request.post_data&.include?(post_data_include)
          begin
            JSON.parse(request.post_data)
          rescue JSON::ParserError
            continue.call(request) && next
          end
        end

        continue.call(request) do |response|
          # Check if not a CORS prefetch and finish up if not
          if !response.body&.empty? && response.body
            check_passed = true
            unless additional_search_parameters.nil?
              puts "checking additional search parameters #{additional_search_parameters}"
              body_to_check = Oj.load(response.body)

              search_parameters = additional_search_parameters.split(",")
              search_parameters.each_with_index do |key, index|
                break if body_to_check.nil?

                check_passed = false unless body_to_check.has_key?(key)
                body_to_check = body_to_check[key]
              end
            end

            next if check_passed == false
            response_body = response.body if check_passed == true
          end
        end
      rescue Selenium::WebDriver::Error::WebDriverError
        # Eat them
      rescue StandardError => e
        puts "***********************************************************"
        puts "Error in intercept: #{e}"
        puts "***********************************************************"
      end

      # Now that the intercept is set up, we visit the page we want
      page.driver.browser.navigate.to(url)
      dismiss_cookie_consent

      # We wait until the correct intercept is processed or we've waited 60 seconds
      start_time = Time.now
      while response_body.nil? && (Time.now - start_time) < 60
        sleep(0.1)
      end


      page.driver.execute_script("window.stop();")

      # 1. Fix the ability to dettect if a page is removed -DONE
      # 2. Fix videos for slideshows - Works for reels?
      # 3. Public liinks

      # Check if something failed before we continue. Use the fake test to test
      raise ContentUnavailableError.new("Response body nil") if response_body.nil?

      Oj.load(response_body)
    ensure
      # page.quit
      # TRY THIS TO MAKE SURE CHROME GETS CLOSED?
      # We may also want to not do this and make sure the same browser is reused instead for cookie purposes
      # NOW wer'e trying this 2024-05-28
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
        login_button = page.all(:xpath, "//div[text()='Log in'] | //a[text()='Log In']", wait: 2).last
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

        if page.has_xpath?('//*[@name="username"]')
          fill_in("username", with: ENV["INSTAGRAM_USER_NAME"])
        elsif page.has_xpath?('//*[@name="email"]')
          fill_in("email", with: ENV["INSTAGRAM_USER_NAME"])
        else
          raise "Couldn't find username field"
        end

        fill_in("password", with: ENV["INSTAGRAM_PASSWORD"])

        dismiss_cookie_consent

        begin
          find_button("Log in").click() # Note: "Log in" (lowercase `in`) should be exact instead, it redirects to Facebook's login page
        rescue Capybara::ElementNotFound; end # If we can't find it don't break horribly, just keep waiting

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
