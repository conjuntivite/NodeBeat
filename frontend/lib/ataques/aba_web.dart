import 'package:web/web.dart' as web;

void abrirMapaEmNovaAba() => web.window.open('${Uri.base.path}#/tv', '_blank');
bool abaVisivel() => web.document.visibilityState == 'visible';

String? temaTvSalvo() => web.window.localStorage.getItem('nodebeat_tv_tema');
void salvarTemaTv(String tema) => web.window.localStorage.setItem('nodebeat_tv_tema', tema);

String? paletaTvSalva() => web.window.localStorage.getItem('nodebeat_tv_paleta');
void salvarPaletaTv(String id) => web.window.localStorage.setItem('nodebeat_tv_paleta', id);
