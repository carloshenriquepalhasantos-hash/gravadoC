# gravadoC

gravadoC é um aplicativo para Windows feito com Flutter e Dart para gravar,
editar e exportar telas e câmeras.

## Recursos

- Captura de tela ou janela no Windows.
- Captura de câmera com posição, tamanho e cadeado.
- Captura opcional de microfone e áudio do sistema.
- Seleção de atraso antes da gravação.
- Atalho configurável para iniciar e parar.
- Exportação em MP4 com FFmpeg.
- Editor com clips, timeline, imagens, transições e sons.
- Divisão de clips pelo clique direito ou duplo clique.
- Controles separados para áudio e volume.
- Kinetic Cursor para suavização e destaque do mouse.
- Edição de duração de imagens e sons.
- Botão de suporte com WhatsApp e Instagram.

## Tecnologias

- Flutter
- Dart
- FFmpeg
- flutter_webrtc
- media_kit

## Executar em modo desenvolvimento

```powershell
flutter pub get
flutter run -d windows
```

## Compilar para Windows

```powershell
flutter build windows --release
```

O executável será gerado em:

```text
build/windows/x64/runner/Release/gravadoC.exe
```

## Contribuição

Contribuições são bem-vindas. Desenvolvedores podem corrigir erros, melhorar
a interface, otimizar o FFmpeg e adicionar recursos compatíveis com o projeto.

Todas as contribuições devem chegar por Pull Request. Não envie commits
diretos para a branch principal.

### Regra obrigatória do suporte

O botão de suporte deve permanecer no projeto e não pode ser removido,
alterado ou substituído por contribuidores externos sem aprovação explícita
do criador.

Arquivos protegidos:

- `lib/main.dart`
- `lib/recorder_page.dart`
- `README.md`

Alterações nesses arquivos precisam de aprovação do criador antes do merge.

## Contato do criador

- WhatsApp: (49) 99710-357
- Instagram: https://www.instagram.com/carloshenriquepalha/
- Projetos: software, sites, aplicativos Android e Apple
