import 'package:web/web.dart' as web;

void abrirMapaEmNovaAba() => web.window.open('${Uri.base.path}#/tv', '_blank');
bool abaVisivel() => web.document.visibilityState == 'visible';

String? paletaTvSalva() => web.window.localStorage.getItem('nodebeat_tv_paleta');
void salvarPaletaTv(String id) => web.window.localStorage.setItem('nodebeat_tv_paleta', id);
