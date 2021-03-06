library(shiny)
library(bslib)
library(ggplot2)
library(thematic)
library(patchwork)
library(ggtext)
library(glue)

# Default is use caching
if (getOption("cache", TRUE)) {
  bindCache <- shiny::bindCache
  print("Enabling caching")
} else {
  bindCache <- function(x, ...) x
  print("Disabling caching")
}

source('helpers.R')

# Builds theme object to be supplied to ui
my_theme <- bs_theme(bootswatch = "cerulean",
                     base_font = font_google("Righteous"),
                     "font-size-base" = "1.1rem") %>%
  bs_add_rules("
    #source_link {
      position: fixed;
      top: 5px;
      right: 5px;
      font-size: 0.9rem;
      font-weight: lighter;
    }")

# Let thematic know to use the font from bs_lib
thematic_on(font = "auto")

# We have an already build station to city df we are using for lookups
station_to_city <- read_rds(here("data/station_to_city.rds"))

# Some cities have multiple stations but we only want users to see unique cities
unique_cities <- unique(station_to_city$city)

# We start with a random city in the back button and have a random city jump button
get_random_city <- function(){ sample(unique_cities, 1) }

ui <- fluidPage(
  theme = my_theme,
  includeCSS("styles.css"),
  div(id = "header",
      titlePanel("Explore your weather"),
      labeled_input('city-selector', "Search for a city",
                    selectizeInput('city', label = NULL,
                                   choices = c("", unique_cities),
                                   multiple = FALSE)),
      labeled_input("prev_city_btn", "Return to previous city",
                    actionButton('prev_city', textOutput('prev_city_label'))),
      labeled_input("rnd_city_btn", "Try a random city",
                    actionButton('rnd_city', icon('dice')))),
  plotOutput("weather_plot", height = 850),
  div(id = "contributing_stations",
      span("Stations contributing data"),
      span("Click on station to go to its dataset."),
      uiOutput('station_info') ),
  div(id = "data_info",
      icon("database"), "Data sourced from",
      a(href = "https://www.ncdc.noaa.gov/data-access/land-based-station-data/land-based-datasets/climate-normals", "NOAA Climate Normals"),
      "generated by taking average temperatures from weather stations over the years 1982-2010.",
      "For cities with multiple weather stations the average across all reporting stations is used."),
  div(id = "source_link", a(href = "https://github.com/rstudio/shiny_app_stories/blob/master/weather_lookup/", "View source code on github", icon("github")))
)


server <- function(input, output, session) {
  # If the URL contains a city on load, use that city instead of the default of ann arbor
  bookmarked_city <- parse_url_hash(isolate(getUrlHash()))
  current_city <- reactiveVal( if(bookmarked_city %in% unique_cities) bookmarked_city else "Ann Arbor, MI")
  updateSelectizeInput(inputId = "city", selected = isolate(current_city()))

  # A book-keeping reactive so we can have a previous city button
  previous_city <- reactiveVal(NULL)

  observe({
    req(input$city)
    # Set the previous city to the non-updated current city. If app is just
    # starting we want to populate the previous city button with a random city,
    # not the current city
    selected_city <- isolate(current_city())
    just_starting <- selected_city == input$city
    previous_city(if(just_starting) get_random_city() else selected_city)

    # Current city now can be updated to the newly selected city
    current_city(input$city)

    # Update the query string so the app will know what to do.
    updateQueryString(make_url_hash(current_city()), mode = "push")
  })

  observe({
    updateSelectizeInput(inputId = "city", selected = isolate(previous_city()))
  }) %>% bindEvent(input$prev_city)

  observe({
    updateSelectizeInput(inputId = "city", selected = get_random_city())
  }) %>% bindEvent(input$rnd_city)

  city_data <- reactive({
    req(input$city, cancelOutput = TRUE)

    withProgress(message = 'Fetching data from NOAA', {
      incProgress(0, detail = "Gathering all stations within city")
      stations <- filter(station_to_city, city == input$city)

      # Not every station has both temperature and precipitation data. To deal
      # with this, loop through all stations in a city try to extract whatever
      # data is present. If a city has a lot of stations, like Fairbanks, AK,
      # this this can take a while
      incProgress(1/4, detail = "Downloading data from all found stations")
      stations <- stations %>%
        mutate(url = build_station_url(station),
               data = safe_map(url, readr::read_file))

      # If we have multiple stations with data we just collapse it to the mean
      collapse_stations <- . %>%
        reduce(bind_rows, .init = tibble(date = Date())) %>%
        group_by(date) %>%
        summarise_all(mean)

      incProgress(2/4, detail = "Extracting temperature data")
      stations$temp_res <- safe_map(stations$data, get_temp_data)
      temperature <- collapse_stations(stations$temp_res)

      incProgress(3/4, detail = "Extracting precipitation data")
      stations$prcp_res <- safe_map(stations$data, get_prcp_data)
      precipitation <- collapse_stations(stations$prcp_res)

      incProgress(1, detail = "Packaging data for app")
      list(temperature = temperature,
           precipitation = precipitation,
           has_temp = nrow(temperature) != 0,
           has_prcp = nrow(precipitation) != 0,
           station_info = stations %>%
             mutate(had_temp = !map_lgl(temp_res, is.null),
                    had_prcp = !map_lgl(prcp_res, is.null)) %>%
             select(-data, -temp_res, -prcp_res))
    })
  }) %>%
    # Our results will always be the same for a given city, so cache on that key
    bindCache(input$city)

  output$station_info <- renderUI({
    # Let the user know what stations went into the plot they're seeing and
    # allow them to explore the data directly
    pmap(city_data()$station_info,
         function(url, station, had_temp, had_prcp, ...){
           div(class = "station_bubble",
               a(href = url, target = "_blank",
                 station, if(had_temp) icon('thermometer-half'), if(had_prcp) icon('cloud-rain')))
         })
  })

  output$prev_city_label <- renderText({ previous_city() })

  output$weather_plot <- renderPlot({
    req(city_data())

    withProgress(message = 'Building plots', max = 3, {

      incProgress(1, detail = "Building temperature plot")
      temp_plot <- if(city_data()$has_temp) {
        build_temp_plot(city_data()$temperature)
      } else {
        grid::textGrob(glue("Sorry, no temperature data is available for {input$city}, try a nearby city."))
      }

      incProgress(2, detail = "Building precipitation plot")
      prcp_plot <- if(city_data()$has_prcp) {
        build_prcp_plot(city_data()$precipitation)
      } else {
        grid::textGrob(glue("Sorry, no precipitation data is available for {input$city}, try a nearby city."))
      }

      # Setup layout such that temperature data is top large plot unless it is missing when precipitation is the top plot
      incProgress(3, detail = "Merging plots")
      p <- if(city_data()$has_temp){
        temp_plot / prcp_plot
      } else {
        prcp_plot / temp_plot
      }

      p +
        plot_layout(heights = c(2, 1)) +
        plot_annotation(title = glue('Weather normals over the year for {input$city}'),
                        caption = glue("See more at connect.rstudioservices.com/explore_your_weather/{make_url_hash(input$city)}"),
                        theme = theme(plot.title = element_text(size = 30, hjust = 0.5))) &
        scale_x_date(name = "", date_labels = "%b", breaks = twelve_month_seq,
                     minor_breaks = NULL, expand = expansion(mult = c(0, 0))) &
        theme(text = element_text(size = 18),
              axis.text.x = element_text(hjust = 0),
              axis.text.y = element_markdown(),
              panel.grid.major = element_line(color = "grey70", size = 0.2),
              panel.grid.minor = element_line(color = "grey85", size = 0.2))
    })
  }) %>%
    bindCache(input$city, sizePolicy = sizeGrowthRatio(width = 400, height = 600))
}

# Run the application
shinyApp(ui = ui, server = server)
