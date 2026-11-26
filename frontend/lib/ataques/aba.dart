import 'aba_stub.dart' if (dart.library.js_interop) 'aba_web.dart' as impl;

/// Abre o mapa em tela cheia noutra aba, em /tv (no-op fora do navegador).
void abrirMapaEmNovaAba() => impl.abrirMapaEmNovaAba();

/// Aba em primeiro plano? Oculta, o mapa não consulta o servidor.
bool abaVisivel() => impl.abaVisivel();

/// Id da paleta do mapa na TV, guardado no navegador.
String? paletaTvSalva() => impl.paletaTvSalva();
void salvarPaletaTv(String id) => impl.salvarPaletaTv(id);
