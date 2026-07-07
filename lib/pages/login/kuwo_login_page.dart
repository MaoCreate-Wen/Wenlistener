import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../state/kuwo_auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/glass_container.dart';

/// Kuwo password + captcha login page.
class KuwoLoginPage extends StatefulWidget {
  const KuwoLoginPage({super.key});

  @override
  State<KuwoLoginPage> createState() => _KuwoLoginPageState();
}

class _KuwoLoginPageState extends State<KuwoLoginPage> {
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  final TextEditingController _code = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KuwoAuthProvider>().loadCaptcha();
    });
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_user.text.isEmpty || _pass.text.isEmpty || _code.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写所有字段')),
      );
      return;
    }
    final bool ok = await context.read<KuwoAuthProvider>().login(
          username: _user.text.trim(),
          password: _pass.text,
          verifyCode: _code.text.trim(),
        );
    if (ok && mounted) {
      if (context.canPop()) context.pop();
    } else if (mounted) {
      // Refresh captcha on failure.
      _code.clear();
      context.read<KuwoAuthProvider>().loadCaptcha();
    }
  }

  @override
  Widget build(BuildContext context) {
    final KuwoAuthProvider auth = context.watch<KuwoAuthProvider>();
    final bool loading = auth.step == KuwoLoginStep.loggingIn ||
        auth.step == KuwoLoginStep.loadingCaptcha;

    return AppScaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('登录酷我音乐', style: AppTypography.titleM),
        leading: IconButton(
          tooltip: '返回',
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.onSurface, size: 20),
          onPressed: () {
            if (context.canPop()) context.pop();
          },
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppDimens.space24),
          child: GlassContainer(
            padding: const EdgeInsets.all(AppDimens.space24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('酷我账号', style: AppTypography.titleM),
                const SizedBox(height: AppDimens.space20),
                // Username
                TextField(
                  controller: _user,
                  decoration: const InputDecoration(
                    hintText: '用户名 / 手机号 / 邮箱',
                    prefixIcon: Icon(Icons.person_rounded),
                  ),
                  style: AppTypography.body,
                  textInputAction: TextInputAction.next,
                  enabled: !loading,
                ),
                const SizedBox(height: AppDimens.space16),
                // Password
                TextField(
                  controller: _pass,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    hintText: '密码',
                    prefixIcon: const Icon(Icons.lock_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  style: AppTypography.body,
                  textInputAction: TextInputAction.next,
                  enabled: !loading,
                ),
                const SizedBox(height: AppDimens.space16),
                // Captcha row
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _code,
                        decoration: const InputDecoration(
                          hintText: '验证码',
                          prefixIcon: Icon(Icons.security_rounded),
                        ),
                        style: AppTypography.body,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        enabled: !loading,
                      ),
                    ),
                    const SizedBox(width: AppDimens.space12),
                    GestureDetector(
                      onTap: loading
                          ? null
                          : () => context
                              .read<KuwoAuthProvider>()
                              .loadCaptcha(),
                      child: Container(
                        width: 100,
                        height: 48,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(AppDimens.radiusSm),
                          color: AppColors.surfaceGlass,
                        ),
                        child: _CaptchaImage(auth: auth),
                      ),
                    ),
                  ],
                ),
                if (auth.errorMsg != null) ...<Widget>[
                  const SizedBox(height: AppDimens.space12),
                  Text(
                    auth.errorMsg!,
                    style: AppTypography.caption
                        .copyWith(color: Colors.redAccent),
                  ),
                ],
                const SizedBox(height: AppDimens.space24),
                FilledButton(
                  onPressed: loading ? null : _submit,
                  child: loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CaptchaImage extends StatelessWidget {
  final KuwoAuthProvider auth;
  const _CaptchaImage({required this.auth});

  @override
  Widget build(BuildContext context) {
    final bytes = auth.captchaBytes;
    if (auth.step == KuwoLoginStep.loadingCaptcha || bytes == null) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );
  }
}
