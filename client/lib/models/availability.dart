/// 1:1 s `components.schemas.Availability` v docs/openapi.yaml.
enum Availability { available, provisionable, unavailable }

Availability availabilityFromJson(String? value) => switch (value) {
      'available' => Availability.available,
      'provisionable' => Availability.provisionable,
      _ => Availability.unavailable,
    };
