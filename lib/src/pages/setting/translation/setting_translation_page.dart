import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../service/image_translation_service.dart';
import '../../../service/on_device_translation/llm_page_translator.dart';
import '../../../service/on_device_translation/on_device_translation_service.dart';
import '../../../service/translation_runtime_service.dart';
import '../../../setting/translation_setting.dart';
import '../../../utils/toast_util.dart';

class SettingTranslationPage extends StatefulWidget {
  const SettingTranslationPage({super.key});

  @override
  State<SettingTranslationPage> createState() => _SettingTranslationPageState();
}

class _SettingTranslationPageState extends State<SettingTranslationPage> {
  late final TextEditingController serviceUrlController;
  late final TextEditingController apiTokenController;
  late final TextEditingController apiBaseUrlController;
  late final TextEditingController apiKeyController;
  late final TextEditingController apiModelController;
  late final TextEditingController sourceLanguageController;
  late final TextEditingController targetLanguageController;
  late final TextEditingController timeoutController;
  bool testing = false;
  late String translationProvider;
  late bool disableThinking;
  late String engine;
  late String modelSource;

  bool get onDevice => TranslationSetting.supportsOnDevice && engine == TranslationEngine.onDevice;

  @override
  void initState() {
    super.initState();
    translationRuntimeService.refreshRuntime();
    serviceUrlController = TextEditingController(
      text: translationSetting.serviceUrl.value,
    );
    apiTokenController = TextEditingController(
      text: translationSetting.apiToken.value,
    );
    apiBaseUrlController =
        TextEditingController(text: translationSetting.apiBaseUrl.value);
    apiKeyController =
        TextEditingController(text: translationSetting.apiKey.value);
    apiModelController =
        TextEditingController(text: translationSetting.apiModel.value);
    translationProvider = translationSetting.translationProvider.value;
    disableThinking = translationSetting.disableThinking.value;
    engine = translationSetting.engine.value;
    modelSource = translationSetting.modelSource.value;
    if (onDevice) {
      translationProvider = 'openai_compatible';
    }
    sourceLanguageController = TextEditingController(
      text: translationSetting.sourceLanguage.value,
    );
    targetLanguageController = TextEditingController(
      text: translationSetting.targetLanguage.value,
    );
    timeoutController = TextEditingController(
      text: translationSetting.requestTimeoutSeconds.value.toString(),
    );
  }

  @override
  void dispose() {
    serviceUrlController.dispose();
    apiTokenController.dispose();
    apiBaseUrlController.dispose();
    apiKeyController.dispose();
    apiModelController.dispose();
    sourceLanguageController.dispose();
    targetLanguageController.dispose();
    timeoutController.dispose();
    super.dispose();
  }

  Future<void> save() async {
    await translationSetting.save(
      serviceUrl: serviceUrlController.text,
      apiToken: apiTokenController.text,
      translationProvider: translationProvider,
      apiBaseUrl: apiBaseUrlController.text,
      apiKey: apiKeyController.text,
      apiModel: apiModelController.text,
      disableThinking: disableThinking,
      sourceLanguage: sourceLanguageController.text,
      targetLanguage: targetLanguageController.text,
      requestTimeoutSeconds: int.tryParse(timeoutController.text) ?? 300,
      engine: engine,
      modelSource: modelSource,
    );
    toast('saveSuccess'.tr);
  }

  Future<void> testConnection() async {
    await save();
    setState(() => testing = true);
    final bool success = onDevice ? await _testLlm() : await imageTranslationService.testConnection();
    if (mounted) {
      setState(() => testing = false);
    }
    if (onDevice) {
      toast(success ? 'translationLlmConnected'.tr : 'translationLlmUnavailable'.tr, isShort: false);
      return;
    }
    toast(
      success
          ? 'translationServiceConnected'.tr
          : 'translationServiceUnavailable'.tr,
      isShort: false,
    );
  }

  Future<bool> _testLlm() async {
    try {
      await LlmPageTranslator(
        baseUrl: translationSetting.apiBaseUrl.value,
        apiKey: translationSetting.apiKey.value,
        model: translationSetting.apiModel.value,
        disableThinking: translationSetting.disableThinking.value,
        timeout: const Duration(seconds: 30),
      ).ping();
      return true;
    } catch (_) {
      return false;
    }
  }

  Widget _buildEngineSelector() {
    return SegmentedButton<String>(
      segments: [
        ButtonSegment(value: TranslationEngine.onDevice, label: Text('translationEngineOnDevice'.tr), icon: const Icon(Icons.phone_android)),
        ButtonSegment(value: TranslationEngine.server, label: Text('translationEngineServer'.tr), icon: const Icon(Icons.dns_outlined)),
      ],
      selected: {engine},
      onSelectionChanged: (selection) => setState(() {
        engine = selection.first;
        if (onDevice) {
          translationProvider = 'openai_compatible';
        }
      }),
    );
  }

  Widget _buildModelCard(BuildContext context) {
    return GetBuilder<OnDeviceTranslationService>(
      id: OnDeviceTranslationService.modelsUpdateId,
      builder: (service) {
        final OcrModelStatus status = service.modelStatus;
        final String message = switch (status) {
          OcrModelStatus.installed => 'translationModelsInstalled'.tr,
          OcrModelStatus.downloading => 'translationModelsDownloading'.tr,
          OcrModelStatus.error => 'translationModelsError'.trParams({'error': service.modelError ?? ''}),
          OcrModelStatus.missing => 'translationModelsMissing'.tr,
        };
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(status == OcrModelStatus.installed
                        ? Icons.check_circle
                        : status == OcrModelStatus.error
                            ? Icons.error_outline
                            : Icons.downloading_outlined),
                    const SizedBox(width: 10),
                    Expanded(child: Text('translationModelsTitle'.tr, style: Theme.of(context).textTheme.titleMedium)),
                  ],
                ),
                const SizedBox(height: 10),
                Text(message),
                if (status == OcrModelStatus.downloading) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: service.downloadProgress > 0 ? service.downloadProgress : null),
                  const SizedBox(height: 6),
                  Text('${(service.downloadProgress * 100).toStringAsFixed(0)}%'),
                ],
                const SizedBox(height: 12),
                if (status == OcrModelStatus.downloading)
                  OutlinedButton.icon(onPressed: service.cancelDownload, icon: const Icon(Icons.close), label: Text('cancel'.tr))
                else if (status == OcrModelStatus.installed)
                  TextButton.icon(onPressed: service.deleteModels, icon: const Icon(Icons.delete_outline), label: Text('deleteTranslationModels'.tr))
                else ...[
                  DropdownButtonFormField<String>(
                    initialValue: modelSource,
                    decoration: InputDecoration(labelText: 'translationModelSource'.tr, border: const OutlineInputBorder()),
                    items: [
                      DropdownMenuItem(value: TranslationModelSource.huggingFace, child: Text('translationModelSourceHuggingFace'.tr)),
                      DropdownMenuItem(value: TranslationModelSource.hfMirror, child: Text('translationModelSourceMirror'.tr)),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => modelSource = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () async {
                      translationSetting.modelSource.value = modelSource;
                      await translationSetting.saveBeanConfig();
                      await service.downloadModels();
                    },
                    icon: const Icon(Icons.download),
                    label: Text('downloadTranslationModels'.tr),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('imageTranslation'.tr)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (TranslationSetting.supportsOnDevice) ...[
              _buildEngineSelector(),
              const SizedBox(height: 16),
            ],
            Text(onDevice ? 'onDeviceTranslationHint'.tr : 'translationServiceHint'.tr),
            const SizedBox(height: 20),
            if (onDevice) ...[
              _buildModelCard(context),
              const SizedBox(height: 20),
            ],
            if (GetPlatform.isWindows) ...[
              GetBuilder<TranslationRuntimeService>(
                init: translationRuntimeService,
                id: TranslationRuntimeService.updateId,
                builder: (runtime) => Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              runtime.status == TranslationRuntimeStatus.ready
                                  ? Icons.check_circle
                                  : runtime.status ==
                                          TranslationRuntimeStatus.error
                                      ? Icons.error_outline
                                      : Icons.downloading_outlined,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'translationRuntimeTitle'.tr,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(runtime.message),
                        if (runtime.isBusy) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                              value: runtime.progress > 0
                                  ? runtime.progress / 100
                                  : null),
                          const SizedBox(height: 6),
                          Text('${runtime.progress}%'),
                        ],
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: runtime.isBusy
                              ? null
                              : runtime.isInitialized
                                  ? runtime.start
                                  : runtime.initialize,
                          icon: Icon(runtime.isInitialized
                              ? Icons.play_arrow
                              : Icons.download),
                          label: Text(
                            runtime.isInitialized
                                ? 'startTranslationRuntime'.tr
                                : 'initializeTranslationRuntime'.tr,
                          ),
                        ),
                        if (!runtime.isInitialized) ...[
                          if (runtime.nvidiaAvailable)
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text('useCudaAcceleration'.tr),
                              subtitle: Text('useCudaAccelerationHint'.tr),
                              value: runtime.useCuda,
                              onChanged:
                                  runtime.isBusy ? null : runtime.setUseCuda,
                            ),
                          const SizedBox(height: 8),
                          Text(
                            'translationRuntimeSizeHint'.tr,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
            if (!onDevice) ...[
            TextField(
              controller: serviceUrlController,
              decoration: InputDecoration(
                labelText: 'translationServiceUrl'.tr,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: apiTokenController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'translationApiToken'.tr,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: translationProvider,
              decoration: InputDecoration(
                labelText: 'translationProvider'.tr,
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: 'openai_compatible',
                  child: Text('openAICompatibleApi'.tr),
                ),
                DropdownMenuItem(
                  value: 'nllb',
                  child: Text('nllbLocal'.tr),
                ),
                DropdownMenuItem(
                  value: 'nllb_big',
                  child: Text('nllbBigLocal'.tr),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => translationProvider = value);
                }
              },
            ),
            ],
            if (translationProvider == 'openai_compatible') ...[
              const SizedBox(height: 16),
              TextField(
                controller: apiBaseUrlController,
                decoration: InputDecoration(
                  labelText: 'translationApiBaseUrl'.tr,
                  helperText: 'translationApiBaseUrlHint'.tr,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: apiKeyController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'translationApiKey'.tr,
                  helperText: 'translationApiKeyHint'.tr,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: apiModelController,
                decoration: InputDecoration(
                  labelText: 'translationApiModel'.tr,
                  helperText: 'translationApiModelHint'.tr,
                  border: const OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('disableThinking'.tr),
                subtitle: Text('disableThinkingHint'.tr),
                value: disableThinking,
                onChanged: (value) => setState(() => disableThinking = value),
              ),
            ] else ...[
              const SizedBox(height: 8),
              Text('localTranslationModelHint'.tr),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: sourceLanguageController,
                    decoration: InputDecoration(
                      labelText: 'sourceLanguage'.tr,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: targetLanguageController,
                    decoration: InputDecoration(
                      labelText: 'targetLanguage'.tr,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: timeoutController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'translationTimeout'.tr,
                suffixText: 's',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: save,
              icon: const Icon(Icons.save),
              label: Text('saveTranslationSettings'.tr),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: testing ? null : testConnection,
              icon: testing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.health_and_safety_outlined),
              label: Text('testConnection'.tr),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () async {
                await imageTranslationService.clearCache();
                toast('translationCacheCleared'.tr);
              },
              icon: const Icon(Icons.delete_sweep_outlined),
              label: Text('clearTranslationCache'.tr),
            ),
          ],
        ),
      ),
    );
  }
}
