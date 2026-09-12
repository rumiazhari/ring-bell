# Environment visual matrix

Captured by `godot --path . -- --envcapture` (`debug/environment_capture.gd`) on a street-canyon fixture.

| frame | time / weather | mean luma | p01 | p99 | crushed black | blown | file |
|---|---|---|---|---|---|---|---|
| 01-clear-morning | 8:00 clear | mean 0.225 | p01 0.156 | p99 0.453 | black 0.00% | blown 0.00% | res://captures/environment/01-clear-morning.png |
| 02-clear-noon | 12:00 clear | mean 0.280 | p01 0.172 | p99 0.531 | black 0.00% | blown 0.00% | res://captures/environment/02-clear-noon.png |
| 03-sunset | 18:30 partly_cloudy | mean 0.173 | p01 0.125 | p99 0.313 | black 0.00% | blown 0.00% | res://captures/environment/03-sunset.png |
| 04-clear-midnight | 0:00 clear | mean 0.065 | p01 0.031 | p99 0.109 | black 0.00% | blown 0.00% | res://captures/environment/04-clear-midnight.png |
| 05-fog-morning | 7:00 fog | mean 0.152 | p01 0.094 | p99 0.359 | black 0.00% | blown 0.00% | res://captures/environment/05-fog-morning.png |
| 06-cloudy-afternoon | 15:00 cloudy | mean 0.285 | p01 0.188 | p99 0.578 | black 0.00% | blown 0.00% | res://captures/environment/06-cloudy-afternoon.png |
| 07-light-rain-day | 11:00 light_rain | mean 0.268 | p01 0.156 | p99 0.656 | black 0.00% | blown 0.00% | res://captures/environment/07-light-rain-day.png |
| 08-heavy-rain-night | 22:00 heavy_rain | mean 0.125 | p01 0.031 | p99 0.547 | black 0.00% | blown 0.00% | res://captures/environment/08-heavy-rain-night.png |
| 09-storm-day | 14:00 storm | mean 0.263 | p01 0.172 | p99 0.594 | black 0.00% | blown 0.00% | res://captures/environment/09-storm-day.png |
| 10-storm-night | 23:00 storm | mean 0.165 | p01 0.047 | p99 0.563 | black 0.00% | blown 0.00% | res://captures/environment/10-storm-night.png |
| 11-lightning-flash | storm 14:00 | mean 0.394 | p99 0.67 | flash +0.105 | res://captures/environment/11-lightning-flash.png |
| 12/13-road dry -> wet | clear 12:00 | mean 0.284 -> 0.324 | p99 0.516 -> 0.547 | global wetness reaches the shader | 12-road-dry.png, 13-road-wet.png |

Metric failures: 0
