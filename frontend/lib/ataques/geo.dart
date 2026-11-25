import 'dart:ui';

// Destino fixo: a sede (Santa Catarina).
const destinoLat = -27.10, destinoLon = -52.62;

const _latMax = 84.0, _latMin = -58.0;

// Equiretangular com corte de latitude em 84..-58.
Offset projetar(double lat, double lon, Size s) {
  final la = lat.clamp(_latMin, _latMax);
  final lo = lon.clamp(-180.0, 180.0);
  return Offset((lo + 180) / 360 * s.width, (_latMax - la) / (_latMax - _latMin) * s.height);
}

// Ponto médio deslocado para cima em 30% da distância.
Offset controleArco(Offset a, Offset b) {
  final m = (a + b) / 2;
  return Offset(m.dx, m.dy - (b - a).distance * 0.3);
}

// Bézier quadrática.
Offset pontoNoArco(Offset a, Offset c, Offset b, double t) {
  final u = 1 - t;
  return a * (u * u) + c * (2 * u * t) + b * (t * t);
}
