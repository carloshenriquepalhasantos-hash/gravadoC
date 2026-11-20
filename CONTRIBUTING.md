# Contribuindo com o gravadoC

## Como contribuir

1. Crie um fork do projeto.
2. Crie uma branch separada para sua alteração.
3. Execute testes e análise antes de enviar.
4. Abra um Pull Request para `main`.

## Requisitos

```powershell
flutter pub get
dart format lib test
flutter analyze
flutter test
```

Não inclua no Pull Request:

- `build/`
- `.dart_tool/`
- gravações pessoais
- arquivos temporários
- credenciais ou dados privados

## Proteção do suporte

Contribuições não podem remover ou ocultar o botão **Suporte - Pedidos**.

Alterações em `lib/main.dart`, `lib/recorder_page.dart` e `README.md`
precisam de aprovação do criador do projeto.
