import requests, json

with open('api_key.txt') as f:
    API_key = f.read().strip()

city_name = 'San Francisco'
state_code = 'CA'
country_code = 'US'

response = requests.get(
    f'https://api.openweathermap.org/geo/1.0/direct?q={city_name},{state_code},{country_code}&appid={API_key}'
)
response.raise_for_status()

response_data = json.loads(response.text)
lat = response_data[0]['lat']
lon = response_data[0]['lon']

print(f'Latitude: {lat}, Longitude: {lon}')

response = requests.get(
    f'https://api.openweathermap.org/data/2.5/weather?lat={lat}&lon={lon}&appid={API_key}'
)
response.raise_for_status()
response_data = json.loads(response.text)

weather_desc = response_data['weather'][0]['description']
temp_kelvin = response_data['main']['temp']
temp_celsius = round(temp_kelvin - 273.15, 1)
temp_fahrenheit = round(temp_kelvin * (9/5) - 459.67, 1)

print(f'Current weather: {weather_desc}')
print(f'Temperature: {temp_celsius}°C / {temp_fahrenheit}°F')

response = requests.get(
    f'https://api.openweathermap.org/data/2.5/forecast?lat={lat}&lon={lon}&appid={API_key}'
)
response.raise_for_status()
response_data = json.loads(response.text)

forecast_list = response_data['list']  # 40 entries, 3-hour increments over 5 days
for entry in forecast_list[:5]:  # just print the first 5 for now
    temp = round(entry['main']['temp'] - 273.15, 1)
    desc = entry['weather'][0]['description']
    print(f"{entry['dt_txt']}: {desc}, {temp}°C")