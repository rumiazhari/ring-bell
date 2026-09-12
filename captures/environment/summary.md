# Environment visual matrix

Captured by `godot --path . -- --envcapture` (`debug/environment_capture.gd`) on a street-canyon fixture.

| frame | time / weather | mean luma | p01 | p99 | crushed black | blown | file |
|---|---|---|---|---|---|---|---|
| 01-clear-morning | 8:00 clear | mean 0.258 | p01 0.172 | p99 0.609 | black 0.16% | blown 0.28% | res://captures/environment/01-clear-morning.png |
| 02-clear-noon | 12:00 clear | mean 0.287 | p01 0.172 | p99 0.594 | black 0.16% | blown 0.28% | res://captures/environment/02-clear-noon.png |
| 03-sunset | 18:30 partly_cloudy | mean 0.221 | p01 0.141 | p99 0.625 | black 0.18% | blown 0.29% | res://captures/environment/03-sunset.png |
| 04-clear-midnight | 0:00 clear | mean 0.259 | p01 0.141 | p99 0.625 | black 0.19% | blown 0.30% | res://captures/environment/04-clear-midnight.png |
| 05-fog-morning | 7:00 fog | mean 0.347 | p01 0.203 | p99 0.625 | black 0.15% | blown 0.30% | res://captures/environment/05-fog-morning.png |
| 06-cloudy-afternoon | 15:00 cloudy | mean 0.332 | p01 0.203 | p99 0.609 | black 0.16% | blown 0.29% | res://captures/environment/06-cloudy-afternoon.png |
| 07-light-rain-day | 11:00 light_rain | mean 0.271 | p01 0.156 | p99 0.609 | black 0.16% | blown 0.31% | res://captures/environment/07-light-rain-day.png |
| 08-heavy-rain-night | 22:00 heavy_rain | mean 0.365 | p01 0.203 | p99 0.672 | black 0.13% | blown 0.31% | res://captures/environment/08-heavy-rain-night.png |
| 09-storm-day | 14:00 storm | mean 0.279 | p01 0.172 | p99 0.672 | black 0.17% | blown 0.31% | res://captures/environment/09-storm-day.png |
| 10-storm-night | 23:00 storm | mean 0.375 | p01 0.203 | p99 0.656 | black 0.14% | blown 0.31% | res://captures/environment/10-storm-night.png |
| 11-lightning-flash | storm 14:00 | mean 0.349 | p99 0.64 | flash +0.056 | res://captures/environment/11-lightning-flash.png |
| 12/13-road dry -> wet | clear 12:00 | mean 0.300 -> 0.383 | p99 0.578 -> 0.828 | global wetness reaches the shader | 12-road-dry.png, 13-road-wet.png |

Metric failures: 0
