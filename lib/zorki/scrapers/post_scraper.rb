# frozen_string_literal: true

require "typhoeus"

# rubocop:disable Metrics/ClassLength
module Zorki
  class PostScraper < Scraper
    def parse(id)
      count = 0

      until count == 2
        puts "Retrieving ID #{id}"

        begin
          result = attempt_parse(id)
          break
        rescue ImageRequestZeroSize
          # If the image is zero size, we retry
          puts "Zero sized image found, retrying #{count}"
          count += 1
        end
      end

      raise ImageRequestZeroSize if count == 5

      result
    ensure
      page.quit
      # Make sure it's quit? I'm not sure we really want to do this outside of testing.
    end

    def attempt_parse(id)
      # Stuff we need to get from the DOM (implemented is starred):
      # - User *
      # - Text *
      # - Image * / Images * / Video *
      # - Date *
      # - Number of likes *
      # - Hashtags

      Capybara.app_host = "https://instagram.com"

      # video slideshows https://www.instagram.com/p/CY7KxwYOFBS/?utm_source=ig_embed&utm_campaign=loading
      #
      # TODO: Check if post is available publically before trying to login
      # Should help with the scraping
      # login
      # graphql_object = get_content_of_subpage_from_url(
      #   "https://www.instagram.com/p/#{id}/",
      #   "/graphql/query",
      #   "data,xdt_shortcode_media,edge_sidecar_to_children",
      #   post_data_include: "PolarisPostRootQuery"
      # )

      begin
        graphql_object = get_content_of_subpage_from_url(
                "https://www.instagram.com/p/#{id}/",
                "/graphql/query",
                nil,
                post_data_include: "shortcode"
              )
      rescue StandardError
        # if page.has_xpath? "//span[contains(text(), 'Restricted Video')]"
        login("https://www.instagram.com/p/#{id}/")

        begin
          graphql_object = get_content_of_subpage_from_url(
            "https://www.instagram.com/p/#{id}/",
            "/graphql/query",
            nil,
            post_data_include: "shortcode"
          )
        rescue StandardError; end # TODO: Should do something here
        # end

        if graphql_object.nil?
          # node = page.all('body script', visible: false).find {|s| s.text(:all).include? "Switzerland"}
          script_nodes = page.all("body script", visible: false)
          node = script_nodes.find { |s| s.text(:all).include? "xdt_api__v1__media__shortcode__web_info" }
          unless node.nil?
            json = JSON.parse(node.text(:all))
            graphql_object = json["require"][0][3][0]["__bbox"]["require"][0][3][1]["__bbox"]["result"]
          else
            node = script_nodes.find { |s| s.text(:all).include? "xdt_api__v1__profile_timeline" } if node.nil?
            json = JSON.parse(node.text(:all))
            graphql_object = json["require"][0][3][0]["__bbox"]["require"][0][3][1]["__bbox"]["result"]["data"]["xdt_api__v1__profile_timeline"]
          end
        end
      end

      graphql_object = graphql_object.first if graphql_object.kind_of?(Array)

      # For pages that have been marked misinfo the structure is very different than not
      # If it is a clean post then it's just a schema.org thing, but if it's misinfo it's the old
      # way of deeply nested stuff.
      #
      # First we check which one we're getting
      if graphql_object.has_key?("articleBody")
        # Let's just parse the images first
        images = graphql_object["image"].map do |image|
          Zorki.retrieve_media(image["url"])
        end

        text = graphql_object["articleBody"]
        username = graphql_object["author"]["identifier"]["value"]
        # 2021-04-01T17:07:10-07:00

        date = DateTime.strptime(graphql_object["dateCreated"], "%Y-%m-%dT%H:%M:%S%z")
        interactions = graphql_object["interactionStatistic"]
        number_of_likes = interactions.select do |x|
          x["interactionType"] == "http://schema.org/LikeAction"
        end.first["userInteractionCount"]

        unless graphql_object["video"].empty?
          video_url = graphql_object["video"].first["contentUrl"]
          video = Zorki.retrieve_media(video_url)

          video_preview_image_url = graphql_object["video"].first["thumbnailUrl"]
          video_preview_image = Zorki.retrieve_media(video_preview_image_url)
        end
      elsif graphql_object.has_key?("items") || !graphql_object.dig("data", "xdt_api__v1__media__shortcode__web_info", "items").nil? || !graphql_object.dig("data", "xdt_api__v1__profile_timeline").nil?
        # We need to see if this is a single image post or a slideshow. We do that
        # by looking for a single image, if it's not there, we assume the alternative.

        unless graphql_object.has_key?("items")
          graphql_object = graphql_object.dig("data", "xdt_api__v1__media__shortcode__web_info")
          graphql_object = graphql_object.dig("data", "xdt_api__v1__profile_timeline") if graphql_object.nil?
        end

        item = graphql_object.has_key?("items") ? graphql_object["items"][0] : graphql_object
        unless item.has_key?("video_versions") && !item["video_versions"].nil?
          # Check if there is a slideshow or not
          unless item.has_key?("carousel_media") && !item["carousel_media"].nil?
            # Single image
            image_url = item["image_versions2"]["candidates"][0]["url"]
            images = [Zorki.retrieve_media(image_url)]
          else
            # Slideshow
            images = item["carousel_media"].map do |media|
              Zorki.retrieve_media(media["image_versions2"]["candidates"][0]["url"])
            end
          end
        else
          # some of these I've seen in both ways, thus the commented out lines
          # video_url = graphql_object["entry_data"]["PostPage"].first["graphql"]["shortcode_media"]["video_url"]
          video_url = item["video_versions"][0]["url"]
          video = Zorki.retrieve_media(video_url)
          # video_preview_image_url = graphql_object["entry_data"]["PostPage"].first["graphql"]["shortcode_media"]["display_resources"].last["src"]
          video_preview_image_url = item["image_versions2"]["candidates"][0]["url"]
          video_preview_image = Zorki.retrieve_media(video_preview_image_url)
        end

        unless item["caption"].nil?
          text = item["caption"]["text"]
        else
          text = ""
        end

        username = item["user"]["username"]

        date = nil
        begin
          date = DateTime.strptime(item["taken_at"].to_s, "%s")
        rescue StandardError; end

        number_of_likes = item["like_count"]
      elsif graphql_object.has_key?("data")
        # TODO This is the new way of doing things, we need to figure it out
        # Go through the entire JSON structure (below for now) and make sure it hits all the points

        object = graphql_object["data"]["xdt_shortcode_media"]

        begin
          date = object["edge_media_to_caption"]["edges"].first["node"]["created_at"]
        rescue StandardError
          date = object["taken_at_timestamp"].to_s
        end

        date = DateTime.strptime(date, "%s")

        begin
          text = object["edge_media_to_caption"]["edges"].first["node"]["text"]
        rescue StandardError
          text = ""
        end

        number_of_likes = object["edge_media_preview_like"]["count"]
        username = object["owner"]["username"]
        id = object["shortcode"]

        images = []
        video = nil
        video_preview_image = nil

        if object.has_key?("edge_sidecar_to_children")
          object["edge_sidecar_to_children"]["edges"].each do |edge|
            media = Zorki.retrieve_media(edge["node"]["display_resources"].last["src"])
            images << media if edge["node"]["is_video"] == false

            if edge["node"]["is_video"] == true
              video = media
              video_preview_image = Zorki.retrieve_media(edge["node"]["display_resources"]["display_url"])
              break # We only support one video right now, we'll fix later
            end
          end
        elsif object.has_key?("display_resources")
          if object["is_video"] == true
            video = Zorki.retrieve_media(object["video_url"])
            video_preview_image = Zorki.retrieve_media(object["display_url"])
          else
            images << Zorki.retrieve_media(object["display_resources"].last["src"])
          end
        end

        user = User.from_post_data(object["owner"])
      end

      # If we're logged in and there's a fact-check overlay, we won't have got the video on the first pass
      # so we need to get it now by reloading the page and looking for the video
      if video.nil?
        node = page.all("body script", visible: false).find { |s| s.text(:all).include? "FBPartialPrefetchDuration" }
        if !node.nil?
          json = JSON.parse(node.text(:all))

          graphql_object = json["require"][0][3][0]["__bbox"]["require"][0][3][1]["__bbox"]["result"]["data"]["xdt_api__v1__media__shortcode__web_info"]["items"][0]
          if graphql_object.has_key?("video_versions") && !graphql_object["video_versions"].nil? || graphql_object["video_versions"].empty?
            video_url = graphql_object["video_versions"][0]["url"]
            video = Zorki.retrieve_media(video_url)
            video_preview_image_url = graphql_object["image_versions2"]["candidates"][0]["url"]
            video_preview_image = Zorki.retrieve_media(video_preview_image_url)
          end

          date = DateTime.strptime(graphql_object["taken_at"].to_s, "%s")          # STill need to get the date
        end
      end

      screenshot_file = take_screenshot()

      # This has to run last since it switches pages
      user = User.lookup([username]).first if defined?(user) && user.nil?
      {
        images: images,
        video: video,
        video_preview_image: video_preview_image,
        screenshot_file: screenshot_file,
        text: text,
        date: date,
        number_of_likes: number_of_likes,
        user: user,
        id: id
      }
    end

    def take_screenshot
      # First check if a post has a fact check overlay, if so, clear it.
      # The only issue is that this can take *awhile* to search. Not sure what to do about that
      # since it's Instagram's fault for having such a fucked up obfuscated hierarchy
      #
      # Disabling this because it doesn't work right now when we're not logging in
      # Eventually we want to especially get the login modal closed
      # begin
      #   find_button("Close").click
      #   sleep(1)
      #   find_button("See Post").click
      #   sleep(0.1)
      # rescue Capybara::ElementNotFound
      #   # Do nothing if the element is not found
      # end

      # Take the screenshot and return it
      # rubocop:disable Link/Debugger
      save_screenshot("#{Zorki.temp_storage_location}/instagram_screenshot_#{SecureRandom.uuid}.png")
    rescue Selenium::WebDriver::Error::TimeoutError
      nil
    end
  end
end
