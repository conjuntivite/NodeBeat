import 'package:web/web.dart' as web;

void abrirMapaEmNovaAba() => web.window.open('${Uri.base.path}#/eventos/mapa', '_blank');
bool abaVisivel() => web.document.visibilityState == 'visible';
