import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/utils/cookie_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';
import 'package:webview_flutter/webview_flutter.dart';

typedef OnPageStartedCallback = Future<void> Function(String url, WebViewController controller);

class WebviewPage extends StatefulWidget {
  const WebviewPage({Key? key}) : super(key: key);

  @override
  _WebviewPageState createState() => _WebviewPageState();
}

class _WebviewPageState extends State<WebviewPage> {
  late final String title;
  late final Function? pageStartedCallback;
  late final Function? pageFinishedCallback;
  late final WebViewController controller;

  /// Web login: show native username / password fields under the page. They
  /// take part in Android autofill (saved passwords, also the ones saved in
  /// Chrome), which the embedded web page does not reliably get.
  late final bool fillLogin;
  final TextEditingController _userName = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _obscure = true;

  LoadingState loadingState = LoadingState.loading;

  @override
  void initState() {
    super.initState();

    title = Get.arguments['title'];
    fillLogin = Get.arguments is Map && Get.arguments['fillLogin'] == true;

    if (Get.arguments is Map && Get.arguments['onPageStarted'] is Function) {
      pageStartedCallback = Get.arguments['onPageStarted'];
    } else {
      pageStartedCallback = null;
    }

    if (Get.arguments is Map && Get.arguments['onPageFinished'] is Function) {
      pageFinishedCallback = Get.arguments['onPageFinished'];
    } else {
      pageFinishedCallback = null;
    }

    CookieUtil.parse2Cookies(Get.arguments['cookies']).forEach((cookie) {
      WebViewCookieManager().setCookie(
        WebViewCookie(
          name: cookie.name,
          value: cookie.value,
          domain: Uri.parse(Get.arguments['url']).host,
        ),
      );
    });

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            pageStartedCallback?.call(url, controller);
          },
          onPageFinished: (String url) {
            setStateSafely(() => loadingState = LoadingState.success);
            pageFinishedCallback?.call(url, controller);
          },
          onWebResourceError: (_) => setStateSafely(() => loadingState = LoadingState.success),
        ),
      )
      ..loadRequest(Uri.parse(Get.arguments['url']));
  }

  @override
  void dispose() {
    _userName.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Puts the credentials into E-Hentai's login form and submits it.
  Future<void> _fillAndSubmit() async {
    if (_userName.text.isEmpty || _password.text.isEmpty) {
      toast('userNameOrPasswordMismatch'.tr);
      return;
    }
    final String script = '''
(function (u, p) {
  var user = document.querySelector('input[name="UserName"]');
  var pass = document.querySelector('input[name="PassWord"]');
  if (!user || !pass) { return 'notfound'; }
  user.value = u;
  pass.value = p;
  if (user.form) { user.form.submit(); }
  return 'ok';
})(${jsonEncode(_userName.text)}, ${jsonEncode(_password.text)})''';
    try {
      final Object result = await controller.runJavaScriptReturningResult(script);
      if (result.toString().contains('notfound')) {
        // still on the Cloudflare check or another page
        toast('webLoginFormNotReady'.tr, isShort: false);
        return;
      }
      FocusManager.instance.primaryFocus?.unfocus();
      TextInput.finishAutofillContext();
    } catch (e) {
      toast('webLoginFormNotReady'.tr, isShort: false);
    }
  }

  Widget _buildFillLoginBar(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('webLoginFillHint'.tr, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _userName,
                        autofillHints: const [AutofillHints.username],
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(isDense: true, hintText: 'userName'.tr, border: const OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _fillAndSubmit(),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'password'.tr,
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off, size: 20),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FilledButton.icon(onPressed: _fillAndSubmit, icon: const Icon(Icons.login), label: Text('webLoginFillAndSubmit'.tr)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 1,
        title: LoadingStateIndicator(
          loadingState: loadingState,
          successWidgetBuilder: () => Text(title),
        ),
      ),
      body: WebViewWidget(controller: controller),
      bottomNavigationBar: fillLogin ? _buildFillLoginBar(context) : null,
    );
  }
}
