# Yelp Area Explorer

Yelp Area Explorer is a Flutter application that visualizes restaurant density using the Yelp Fusion API and Google Maps heatmaps.

Instead of relying on a single-radius search, the application performs multi-point grid-based queries across the visible map region to generate a weighted heatmap. This approach enables broader spatial coverage while respecting API constraints.

---

## Overview

This project demonstrates:

- Geospatial querying
- Grid-based search expansion
- Weighted heatmap visualization
- API rate-limit mitigation
- Batched asynchronous execution
- Spatial deduplication

The application retrieves restaurants from Yelp and visualizes their density dynamically on a Google Map.

---

## How It Works

The application generates restaurant density heatmaps by querying Yelp across multiple geographic points.

Workflow:

1. The app retrieves the visible Google Map bounds.
2. The bounds can optionally be expanded to increase coverage.
3. A grid of search centers is generated across the region.
4. Yelp API calls are executed at each grid center.
5. Businesses returned by Yelp are deduplicated using their IDs.
6. Results are converted into weighted heatmap points.
7. The heatmap layer renders restaurant density across the map.

Heatmap intensity is calculated using review count.

Example weighting logic:


weight = 1.0 + clamp(reviewCount / 600.0, 0.0, 2.5)


Higher review counts create stronger heatmap hotspots.

---

## Features

- Search restaurants within the current map view
- Dynamic heatmap visualization
- Adjustable grid size (2×2 to 5×5)
- Adjustable Yelp search radius per grid point
- Adjustable heatmap blur radius (10–50 px)
- Configurable expansion beyond visible map bounds
- Batched request throttling to prevent API rate limits
- Optional marker rendering

---

## Technical Stack

Flutter  
Google Maps Flutter SDK  
Yelp Fusion API  
Dio HTTP Client  

---

## API Key Setup

You must provide a Yelp API key when running the application.

### Step 1: Create a Yelp API Key

Register at:

https://www.yelp.com/developers

### Step 2: Run the Application


flutter run --dart-define=YELP_API_KEY=YOUR_KEY_HERE


The application reads the key using:


class Keys {
static const yelpApiKey = String.fromEnvironment('YELP_API_KEY');
}


Do not commit API keys to source control.

---

## Challenges and Solutions

### Heatmap Radius Constraints

**Problem**

Increasing heatmap radius caused runtime crashes.

**Cause**

Google Maps heatmaps only support radius values between **10 and 50 pixels**.

**Solution**

Clamp the radius within the supported range and increase geographic coverage using larger grid searches rather than larger heatmap blur values.

---

### Yelp 429 Rate Limiting

**Problem**

Expanding the search grid resulted in HTTP 429 rate limit errors.

**Cause**

Multiple simultaneous Yelp requests exceeded API rate limits.

**Solution**

Implemented request batching and throttling to control request bursts.

Recommended configuration:

- Grid size: 3×3
- Maximum concurrent requests: 1–2
- Delay between requests: 300–600 ms

---

### Duplicate Businesses Across Grid Cells

**Problem**

Businesses appeared multiple times due to overlapping search areas.

**Cause**

Adjacent grid queries had overlapping radii.

**Solution**

Deduplicated businesses using their Yelp business ID.

Example approach:


Map<String, YelpBusiness> uniqueBusinesses = {};


---

### Heatmap Radius Misinterpretation

**Problem**

Attempted to increase geographic search coverage by increasing heatmap radius.

**Clarification**

Heatmap radius controls visual blur only and does not affect search coverage.

**Solution**

Expanded geographic search bounds and increased grid density instead.

---

### Marker Performance Issues

**Problem**

Rendering many markers caused map performance issues.

**Solution**

Added an option to disable markers and render heatmap-only mode for better performance.

---

## Performance Considerations

Recommended settings:

- Grid size: 3×3
- Yelp radius per grid cell: 4000–6000 meters
- Heatmap radius: 30–45 px
- Request delay: 300–600 ms

Higher settings increase coverage but may introduce API rate limits or performance degradation.

---

## Installation

Clone the repository:


git clone https://github.com/YOUR_USERNAME/yelp_area_app.git

cd yelp_area_app


Install dependencies:


flutter pub get


Run the application:


flutter run --dart-define=YELP_API_KEY=YOUR_KEY


---

## Future Improvements

Potential enhancements include:

- Map tile based caching
- Automatic refresh when the map camera stops moving
- Exponential backoff retry for API rate limits
- Restaurant clustering mode
- Optional Google Places API integration

