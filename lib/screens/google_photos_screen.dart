import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:carousel_slider/carousel_slider.dart' as car;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:intl/intl.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'package:logger/logger.dart';
import 'package:popover/popover.dart';
import 'package:timesgaze/controllers/auth_controller.dart';
import 'package:timesgaze/repositories/auth_repositories.dart'
    show
        PickerAlbum,
        PickerApiException,
        albumSaveProgressProvider,
        isFetchingPhotosProvider,
        islaunchphoto,
        photosAppProvider,
        pickerAlbumsProvider,
        pickerSessionProvider,
        refreshTokenProvider;

import 'package:timesgaze/screens/album_detail_screen.dart';
import 'package:timesgaze/screens/profile_screen.dart';

import 'package:wakelock_plus/wakelock_plus.dart';

class GooglePhotos extends ConsumerStatefulWidget {
  final FirebaseAnalytics analytics;
  // final List<Map<String, String>> photos1;
  //const GooglePhotos({super.key, required this.photos1});
  GooglePhotos({super.key, required this.analytics});
  final logger = Logger();
  @override
  ConsumerState<GooglePhotos> createState() => _GooglePhotosState();
}

class _GooglePhotosState extends ConsumerState<GooglePhotos>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final logger = Logger();
  final controller = car.CarouselSliderController();
  late TabController _tabController;
  GoogleSignIn? googleSignIn = GoogleSignIn();
  String selectedOption = 'Last In';
  bool _pickerOpened = false;
  bool _openingPicker = false;
  bool _checkingSelection = false;
  String? _currentAccessToken;
  bool _savingAlbum = false;

  void resetCarousel() {
    controller.jumpToPage(0);
  }

  late Timer _timer;
  late InternetConnectionChecker _internetChecker;
  bool _hasInternet = true;
  Timer? _offlineDebounce;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    WidgetsBinding.instance.addObserver(this);
    _setCurrentScreen();
    _internetChecker = InternetConnectionChecker()
      ..onStatusChange.listen((status) {
        final nowOnline = status == InternetConnectionStatus.connected;
        if (nowOnline) {
          // Immediately cancel any pending offline transition
          _offlineDebounce?.cancel();
          final wasOffline = !_hasInternet;
          if (mounted) setState(() => _hasInternet = true);
          if (wasOffline && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Back online'),
                duration: Duration(seconds: 2),
                backgroundColor: Colors.green,
              ),
            );
          }
        } else {
          // Debounce: only mark offline after 5 s of sustained no-internet
          // This prevents false "offline" flashes when returning from the browser
          _offlineDebounce?.cancel();
          _offlineDebounce = Timer(const Duration(seconds: 5), () {
            if (mounted) setState(() => _hasInternet = false);
          });
        }
      });
    _startSignInTimer();
    _loadInitialToken();
    _loadAlbums();
  }

  Future<void> _loadInitialToken() async {
    final token = await _getAccessToken();
    if (token != null && mounted) {
      setState(() => _currentAccessToken = token);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pickerOpened) {
      _pickerOpened = false;
      if (mounted) setState(() => _checkingSelection = true);
      // Small delay: give the API a moment to mark mediaItemsSet=true
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) _checkPickerSelection();
      });
    }
  }

  Future<void> _setCurrentScreen() async {
    await widget.analytics.logEvent(
      name: 'screen_view_PhotoScreen',
      parameters: <String, dynamic>{
        'screen_name': 'PhotoScreen',
        'screen_class': 'PhotoScreen',
      },
    );
    logger.i("Screen view logged: PhotoScreen");
  }

  void _startSignInTimer() {
    _timer = Timer.periodic(Duration(minutes: 52), (Timer timer) {
      print('getTokeennn');
      getToken();
      //ref.read(authControllerProvider).getToken();
      // signInSilently(context, ref);
    });
  }

  getToken() {
    ref
        .read(authControllerProvider)
        .getToken(ref.read(refreshTokenProvider), context);
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging || !mounted) return;
    setState(() {}); // keeps BottomNavigationBar in sync
    if (_tabController.index == 0) {
      final photos = ref.read(photosAppProvider);
      if (photos.isNotEmpty) {
        ref.read(authControllerProvider).loadSelectedPhotos();
      }
    }
  }

  @override
  void dispose() {
    _offlineDebounce?.cancel();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _timer.cancel();
    super.dispose();
  }

  Future<String?> _getAccessToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final doc = await FirebaseFirestore.instance
        .collection('usersAuthDetails')
        .doc(user.uid)
        .get();
    return doc.data()?['access_token'] as String?;
  }

  Future<void> _loadAlbums() async {
    await ref.read(authControllerProvider).loadPickerAlbums();
  }

  Future<void> _deleteAlbum(PickerAlbum album) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Album'),
        content: Text('Delete "${album.name}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(authControllerProvider).deletePickerAlbum(album.id);
    }
  }

  Future<void> _showSaveAlbumDialog() async {
    final defaultName =
        'Album ${DateFormat('MMM d').format(DateTime.now())}';
    final controller = TextEditingController(text: defaultName);
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Save as Album'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Album name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim().isEmpty
                ? defaultName
                : controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && mounted) {
      setState(() => _savingAlbum = true);
      await ref
          .read(authControllerProvider)
          .saveCurrentPhotosAsAlbum(name, _currentAccessToken);
      if (mounted) setState(() => _savingAlbum = false);
    }
  }


  Future<void> _openPicker() async {
    if (_openingPicker) return;
    setState(() => _openingPicker = true);

    try {
      // Always get a fresh token to ensure it carries the Picker scope
      final accessToken =
          await ref.read(authControllerProvider).getFreshAccessToken();
      if (accessToken == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not get Google account token. Please sign in again.')),
          );
        }
        return;
      }

      setState(() => _currentAccessToken = accessToken);

      final session =
          await ref.read(authControllerProvider).createPickerSession(accessToken);
      if (session != null) {
        setState(() => _pickerOpened = true);
      }
    } on PickerApiException catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Photo Picker Error'),
            content: Text(e.message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _openingPicker = false);
    }
  }

  Future<void> _checkPickerSelection({bool isRetry = false}) async {
    final session = ref.read(pickerSessionProvider);
    if (session == null) {
      if (mounted) setState(() => _checkingSelection = false);
      return;
    }

    final accessToken = await _getAccessToken();
    if (accessToken == null) {
      if (mounted) setState(() => _checkingSelection = false);
      return;
    }

    setState(() => _currentAccessToken = accessToken);

    final loaded = await ref
        .read(authControllerProvider)
        .fetchPickerMediaItems(session['sessionId']!, accessToken);

    if (loaded && mounted) {
      setState(() => _checkingSelection = false);
      _showSaveAlbumDialog();
    } else if (!loaded && mounted) {
      if (!isRetry) {
        // Retry once after 2 s — handles slight delay in mediaItemsSet update
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) _checkPickerSelection(isRetry: true);
      } else {
        if (mounted) setState(() => _checkingSelection = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'No photos selected yet. Select photos in Google Photos and try again.'),
          ),
        );
      }
    }
  }

  List<Map<String, dynamic>> shuffleList(List<Map<String, dynamic>> list) {
    var random = Random();
    for (var i = list.length - 1; i > 0; i--) {
      var n = random.nextInt(i + 1);
      var temp = list[i];
      list[i] = list[n];
      list[n] = temp;
    }
    return list;
  }

  Future<void> showFilterOptionsDialog(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Filters'),
          content: Column(
            children: [
              RadioListTile(
                title: Text('Last In'),
                value: 'Last In',
                groupValue: selectedOption,
                onChanged: (value) async {
                  await _handleFilterSelection(context, value!);
                  // setState(() {

                  //   selectedOption = value!;
                  //    showLoadingScreen(context);
                  //   resetCarousel();
                  //   Navigator.pop(context);
                  // });
                },
              ),
              RadioListTile(
                title: Text('Random'),
                value: 'Random',
                groupValue: selectedOption,
                onChanged: (value) async {
                  await _handleFilterSelection(context, value!);
                  // setState(() {
                  //   selectedOption = value!;
                  //   resetCarousel();
                  //   Navigator.pop(context);
                  // });
                },
              ),
              RadioListTile(
                title: Text('Memory Lane'),
                value: 'Memory Lane',
                groupValue: selectedOption,
                onChanged: (value) async {
                  await _handleFilterSelection(context, value!);
                  // setState(() {
                  //   selectedOption = value!;
                  //   resetCarousel();

                  //   Navigator.pop(context);
                  // });
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleFilterSelection(
      BuildContext context, String value) async {
    showLoadingScreen(context);

    await Future.delayed(const Duration(seconds: 10));
    selectedOption = value;
    resetCarousel();

    Navigator.pop(context);

    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    WakelockPlus.enable();
    final bool islaunchframe = ref.watch(islaunchphoto);
    final bool isFetching = ref.watch(isFetchingPhotosProvider);
    final (int, int)? saveProgress = ref.watch(albumSaveProgressProvider);
    final List<PickerAlbum> pickerAlbums = ref.watch(pickerAlbumsProvider);
    final List<Map<String, dynamic>> allPhotos =
        List.from(ref.watch(photosAppProvider));

    DateTime _safeParseDate(dynamic raw) {
      try {
        return DateTime.parse(raw as String? ?? '');
      } catch (_) {
        return DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    final List<Map<String, dynamic>> lastInphotos = List.from(allPhotos)
      ..sort((a, b) =>
          _safeParseDate(b['creationTime'])
              .compareTo(_safeParseDate(a['creationTime'])));

    final List<Map<String, dynamic>> randomphotos =
        shuffleList(List.from(allPhotos));

    final now = DateTime.now();
    List<Map<String, dynamic>> _filterByAge(int days) => allPhotos
        .where((p) =>
            _safeParseDate(p['creationTime'])
                .isAfter(now.subtract(Duration(days: days))))
        .toList();

    final memoryLanePhotos = _filterByAge(7).isNotEmpty
        ? _filterByAge(7)
        : _filterByAge(30).isNotEmpty
            ? _filterByAge(30)
            : _filterByAge(90).isNotEmpty
                ? _filterByAge(90)
                : _filterByAge(180);

    final devicewidth = MediaQuery.of(context).size.width;
    final deviceheight = MediaQuery.of(context).size.height;
    return
                PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: islaunchframe
            ? null
            : AppBar(
                backgroundColor: Colors.white,
                elevation: 0,
                title: const Text(
                  'TimesGaze',
                  style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 18),
                ),
                actions: [
                  if (_hasInternet && allPhotos.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.tune, color: Colors.black),
                      tooltip: 'Filter',
                      onPressed: () => showFilterOptionsDialog(context),
                    ),
                  Button(),
                  const SizedBox(width: 4),
                ],
              ),
        bottomNavigationBar: islaunchframe
            ? null
            : BottomNavigationBar(
                currentIndex: _tabController.index,
                selectedItemColor: const Color.fromARGB(255, 245, 166, 75),
                unselectedItemColor: Colors.grey,
                backgroundColor: Colors.white,
                elevation: 8,
                onTap: (i) => _tabController.animateTo(i),
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.photo_library_outlined),
                    activeIcon: Icon(Icons.photo_library),
                    label: 'Photos',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.photo_album_outlined),
                    activeIcon: Icon(Icons.photo_album),
                    label: 'Albums',
                  ),
                ],
              ),
        body: islaunchframe
            ? Stack(
                children: [
                  Container(
                    width: double.infinity,
                    height: double.infinity,
                    color: Colors.black,
                    child: car.CarouselSlider.builder(
                      carouselController: controller,
                      options: car.CarouselOptions(
                        height: deviceheight,
                        viewportFraction: 1,
                        autoPlay: true,
                        autoPlayInterval: const Duration(seconds: 8),
                        enableInfiniteScroll: false,
                      ),
                      itemCount: (selectedOption == 'Last In')
                          ? lastInphotos.length
                          : (selectedOption == 'Random')
                              ? randomphotos.length
                              : memoryLanePhotos.length,
                      itemBuilder: (context, index, realIndex) {
                        final photoFrame = ((selectedOption == 'Last In')
                                ? lastInphotos[index]['baseUrl']
                                : (selectedOption == 'Random')
                                    ? randomphotos[index]['baseUrl']
                                    : memoryLanePhotos[index]['baseUrl']) ??
                            '';
                        return buildImage(photoFrame, index, context,
                            headers: _currentAccessToken != null
                                ? {'Authorization': 'Bearer $_currentAccessToken'}
                                : null);
                      },
                    ),
                  ),
                  Positioned(
                    top: 20,
                    right: 20,
                    child: ElevatedButton(
                      onPressed: () {
                        ref.read(islaunchphoto.notifier).state = false;
                      },
                      child: Text(
                        'Exit Launch Mode',
                        style: TextStyle(color: Colors.white),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : Stack(
                children: [
                  Column(
                    children: [
                      if (!_hasInternet) _buildOfflineBanner(),
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            _buildPhotosTab(
                              allPhotos: allPhotos,
                              isFetching: isFetching,
                              lastInphotos: lastInphotos,
                              randomphotos: randomphotos,
                              memoryLanePhotos: memoryLanePhotos,
                              pickerAlbums: pickerAlbums,
                              deviceheight: deviceheight,
                              devicewidth: devicewidth,
                            ),
                            _buildAlbumGrid(pickerAlbums, deviceheight),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Full-screen overlays — visible on any tab
                  if (_checkingSelection) _buildCheckingOverlay(),
                  if (_savingAlbum) _buildSavingOverlay(saveProgress),
                ],
              ),
      ),
    );
  }

  Widget _buildPhotosTab({
    required List<Map<String, dynamic>> allPhotos,
    required bool isFetching,
    required List<Map<String, dynamic>> lastInphotos,
    required List<Map<String, dynamic>> randomphotos,
    required List<Map<String, dynamic>> memoryLanePhotos,
    required List<PickerAlbum> pickerAlbums,
    required double deviceheight,
    required double devicewidth,
  }) {
    if (isFetching) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/images/load.gif'),
            const SizedBox(height: 10),
            const Text('Loading your photos...',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
      );
    }

    if (allPhotos.isNotEmpty) {
      final displayPhotos = selectedOption == 'Last In'
          ? lastInphotos
          : selectedOption == 'Random'
              ? randomphotos
              : memoryLanePhotos;
      return Column(
        children: [
          Expanded(
            child: car.CarouselSlider.builder(
              carouselController: controller,
              options: car.CarouselOptions(
                height: double.maxFinite,
                viewportFraction: 1,
                autoPlay: true,
                autoPlayInterval: const Duration(seconds: 8),
                enableInfiniteScroll: false,
              ),
              itemCount: displayPhotos.length,
              itemBuilder: (context, index, realIndex) {
                return buildImage(
                  displayPhotos[index]['baseUrl'] ?? '',
                  index,
                  context,
                  headers: _currentAccessToken != null
                      ? {'Authorization': 'Bearer $_currentAccessToken'}
                      : null,
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: ElevatedButton(
              onPressed: () => ref.read(islaunchphoto.notifier).state = true,
              child: const Text('Launch Photo Frame',
                  style: TextStyle(fontSize: 16, color: Colors.black)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: const BorderSide(
                      color: Color.fromARGB(255, 245, 166, 75), width: 1.5),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // No photos loaded yet
    if (pickerAlbums.isNotEmpty) {
      final selectedCount = pickerAlbums
          .where((a) => a.isEnabled)
          .fold<int>(0, (sum, a) => sum + a.enabledPhotoCount);
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.photo_library_outlined,
                size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No photos loaded',
                style:
                    TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Go to the Albums tab to select which photos to show',
                style: TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding:
                  EdgeInsets.symmetric(horizontal: deviceheight * 0.04),
              child: selectedCount > 0
                  ? ElevatedButton(
                      onPressed: _loadSelectedPhotos,
                      child: Text('Load $selectedCount Selected Photos'),
                      style: ElevatedButton.styleFrom(
                        minimumSize:
                            const Size(double.infinity, 50),
                        backgroundColor:
                            const Color.fromARGB(255, 245, 166, 75),
                        foregroundColor: Colors.black,
                      ),
                    )
                  : ElevatedButton(
                      onPressed: () => _tabController.animateTo(1),
                      child: const Text('Go to Albums'),
                      style: ElevatedButton.styleFrom(
                        minimumSize:
                            const Size(double.infinity, 50),
                        backgroundColor:
                            const Color.fromARGB(255, 245, 166, 75),
                        foregroundColor: Colors.black,
                      ),
                    ),
            ),
          ],
        ),
      );
    }

    return _buildPickerEmptyState(deviceheight);
  }

  Widget _buildCheckingOverlay() {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 40),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 56,
                height: 56,
                child: CircularProgressIndicator(
                  color: Color.fromARGB(255, 245, 166, 75),
                  strokeWidth: 5,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Loading your selected photos…',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Just a moment while we fetch your selection from Google Photos.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSavingOverlay((int, int)? progress) {
    final downloaded = progress?.$1 ?? 0;
    final total = progress?.$2 ?? 0;
    final hasProgress = total > 0;
    final progressValue =
        hasProgress && downloaded > 0 ? downloaded / total : null;

    final message = !hasProgress
        ? 'Creating album…'
        : downloaded == 0
            ? 'Preparing photos…'
            : 'Downloading photo $downloaded of $total';

    return Container(
      color: Colors.black54,
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 40),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: CircularProgressIndicator(
                  value: progressValue,
                  color: const Color.fromARGB(255, 245, 166, 75),
                  backgroundColor: Colors.grey[200],
                  strokeWidth: 5,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                message,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 15),
                textAlign: TextAlign.center,
              ),
              if (hasProgress) ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progressValue,
                    color: const Color.fromARGB(255, 245, 166, 75),
                    backgroundColor: Colors.grey[200],
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$downloaded of $total photos',
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOfflineBanner() {
    return Container(
      width: double.infinity,
      color: Colors.orange.shade50,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: Row(
        children: const [
          Icon(Icons.wifi_off, size: 14, color: Colors.deepOrange),
          SizedBox(width: 6),
          Text(
            'Offline — showing saved albums',
            style: TextStyle(fontSize: 12, color: Colors.deepOrange),
          ),
        ],
      ),
    );
  }

  void _openAlbumDetail(PickerAlbum album) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album)),
    );
  }

  void _toggleAlbumEnabled(PickerAlbum album) {
    ref
        .read(authControllerProvider)
        .updateAlbumEnabled(album.id, !album.isEnabled);
  }

  void _loadSelectedPhotos() {
    ref.read(authControllerProvider).loadSelectedPhotos();
    _tabController.animateTo(0);
  }

  Widget _buildAlbumGrid(List<PickerAlbum> albums, double deviceheight) {
    final selectedPhotoCount = albums
        .where((a) => a.isEnabled)
        .fold<int>(0, (sum, a) => sum + a.enabledPhotoCount);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const Text(
                'My Albums',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: (_hasInternet && !_openingPicker) ? _openPicker : null,
                icon: _openingPicker
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color.fromARGB(255, 245, 166, 75),
                        ),
                      )
                    : const Icon(Icons.add_photo_alternate, size: 16),
                label: Text(_openingPicker ? 'Opening…' : 'Add Album'),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(10),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemCount: albums.length,
            itemBuilder: (ctx, i) {
              final album = albums[i];
              return GestureDetector(
                onTap: () => _openAlbumDetail(album),
                onLongPress: () => _deleteAlbum(album),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Thumbnail
                      album.thumbnailPath != null
                          ? Image.file(File(album.thumbnailPath!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: Colors.grey[300],
                                child: const Icon(Icons.photo_album,
                                    color: Colors.grey),
                              ))
                          : Container(
                              color: Colors.grey[300],
                              child: const Icon(Icons.photo_album,
                                  color: Colors.grey)),
                      // Dim overlay for disabled albums
                      if (!album.isEnabled)
                        Container(color: Colors.black45),
                      // Bottom gradient + text
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.65)
                              ],
                              stops: const [0.55, 1.0],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 6,
                        right: 26,
                        bottom: 6,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              album.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600),
                            ),
                            Text(
                              album.isEnabled
                                  ? '${album.enabledPhotoCount}/${album.photoPaths.length}'
                                  : '${album.photoPaths.length} · off',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 9),
                            ),
                          ],
                        ),
                      ),
                      // Enable/disable badge
                      Positioned(
                        top: 5,
                        right: 5,
                        child: GestureDetector(
                          onTap: () => _toggleAlbumEnabled(album),
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: album.isEnabled
                                  ? const Color.fromARGB(255, 245, 166, 75)
                                  : Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              album.isEnabled ? Icons.check : Icons.remove,
                              size: 12,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: ElevatedButton(
            onPressed: selectedPhotoCount > 0 ? _loadSelectedPhotos : null,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
              backgroundColor: const Color.fromARGB(255, 245, 166, 75),
              foregroundColor: Colors.black,
              disabledBackgroundColor: Colors.grey[300],
              disabledForegroundColor: Colors.black45,
            ),
            child: Text(
              selectedPhotoCount > 0
                  ? 'View $selectedPhotoCount Selected Photos'
                  : 'No photos selected',
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPickerEmptyState(double deviceheight) {
    if (!_hasInternet) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.wifi_off, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'No internet connection',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Connect to the internet to create albums.\nAlbums you create will be available offline.',
              style: TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }

    final session = ref.watch(pickerSessionProvider);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset('assets/images/nodata.gif'),
        const SizedBox(height: 16),
        const Text(
          'No albums yet',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        const Text(
          'Pick photos from Google Photos to create your first album',
          style: TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: deviceheight * 0.04),
          child: ElevatedButton.icon(
            onPressed: _openingPicker ? null : _openPicker,
            icon: _openingPicker
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.black54,
                    ),
                  )
                : const Icon(Icons.add_photo_alternate),
            label: Text(_openingPicker
                ? 'Opening Google Photos…'
                : 'Create Album from Google Photos'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
              backgroundColor: const Color.fromARGB(255, 245, 166, 75),
              foregroundColor: Colors.black,
            ),
          ),
        ),
        if (session != null) ...[
          const SizedBox(height: 12),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: deviceheight * 0.04),
            child: OutlinedButton(
              onPressed: _checkPickerSelection,
              child: const Text("I've selected my photos — load them"),
            ),
          ),
        ],
      ],
    );
  }

  void previous() =>
      controller.previousPage(duration: const Duration(milliseconds: 500));
  void next() =>
      controller.nextPage(duration: const Duration(milliseconds: 500));
}

Widget buildImage(String source, int index, BuildContext context,
    {Map<String, String>? headers}) {
  final isLocalFile = source.startsWith('/');
  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 12.0),
    color: Colors.grey,
    child: isLocalFile
        ? Image.file(File(source), fit: BoxFit.fill)
        : CachedNetworkImage(
            imageUrl: source,
            httpHeaders: headers,
            fit: BoxFit.fill,
          ),
  );
}

class ListItems extends StatelessWidget {
  const ListItems({Key? key}) : super(key: key);

  // void logOut(WidgetRef ref, BuildContext context) async {
  //   final SharedPreferences prefs = await SharedPreferences.getInstance();
  //   await prefs.setBool('isLoggedIn', false);
  //   ref.read(authControllerProvider).logOut(context);
  //   // AuthRepository(firestore: FirebaseFirestore.instance,auth: FirebaseAuth.instance,googleSignIn: GoogleSignIn()).logOut(context);
  //   Navigator.pop(context);
  //   // Navigator.pushReplacement(
  //   //     context, MaterialPageRoute(builder: (context) => LoginScreen()));
  // }

  void logOut(WidgetRef ref, BuildContext context) async {
    try {
      // Repository handles clearing state, tokens, prefs, and navigation
      await ref.read(authControllerProvider).logOut(context);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logout failed: ${e.toString()}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    //final devicewidth = MediaQuery.of(context).size.width;
    final deviceheight = MediaQuery.of(context).size.height;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: deviceheight * 0.01179),
      child: ListView(
        padding: EdgeInsets.all(deviceheight * 0.01179),
        children: [
          InkWell(
            onTap: () {
              Navigator.of(context)
                ..pop()
                ..push(
                  MaterialPageRoute<ProfileScreen>(
                    builder: (context) => ProfileScreen(),
                  ),
                );
            },
            child: Container(
              height: 0.0589 * deviceheight,
              color: Colors.white,
              child: const Center(child: Text('Profile')),
            ),
          ),
          const Divider(),
          Consumer(builder: (context, ref, _) {
            return InkWell(
              onTap: () => logOut(ref, context),
              child: Container(
                height: 0.0589 * deviceheight,
                color: Colors.white,
                child: const Center(child: Text('Switch Account')),
              ),
            );
          }),
          const Divider(),
          Consumer(builder: (context, ref, _) {
            return InkWell(
              onTap: () => logOut(ref, context),
              child: Container(
                height: 0.0589 * deviceheight,
                color: Colors.white,
                child: const Center(
                    child: Text('Logout',
                        style: TextStyle(color: Colors.red))),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class Button extends StatelessWidget {
  const Button({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final deviceheight = MediaQuery.of(context).size.height;
    final devicewidth = MediaQuery.of(context).size.width;
    return GestureDetector(
      child: const Center(
          child: Icon(
        Icons.more_vert,
        color: Colors.black,
      )),
      onTap: () {
        showPopover(
          context: context,
          bodyBuilder: (context) => const ListItems(),

          direction: PopoverDirection.top,
          width: devicewidth * 0.5555,

          height: 0.28 * deviceheight,
          arrowHeight: 15,
          // arrowWidth: 40,
        );
      },
    );
  }
}

void showLoadingScreen(BuildContext context) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      return PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/images/load.gif'),
                SizedBox(height: 20),
                Text("Refreshing your photos..."),
              ],
            ),
          ),
        ),
      );
    },
  );
}
