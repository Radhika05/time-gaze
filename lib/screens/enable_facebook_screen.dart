import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:logger/logger.dart';
import 'package:timesgaze/common/constants.dart';
import 'package:timesgaze/controllers/auth_controller.dart';
import 'package:timesgaze/screens/google_photos_screen.dart';
import 'package:timesgaze/screens/localStoredPhotos.dart';

 class EnableFacebook extends ConsumerStatefulWidget {
  final FirebaseAnalytics analytics;
      List<Map<String, dynamic>> photos;
  EnableFacebook( {super.key, required this.photos, required this.analytics});

  

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _EnableFacebookState();
}

class _EnableFacebookState extends ConsumerState<EnableFacebook> {
    final logger = Logger();
 @override
  void initState() {
     _setCurrentScreen();
    super.initState();
   
   
  }
 Future<void> _setCurrentScreen() async {
    await widget.analytics.logEvent(
      name: 'screen_view_FacebookScreen',
      parameters: <String, dynamic>{
        'screen_name': 'FacebookScreen',
        'screen_class': 'FacebookScreen',
      },
    );
    logger.i("Screen view logged: FacebookScreen");
  }
  // void signInWithFacebook(BuildContext context, WidgetRef ref) {
  //   ref.read(authControllerProvider).signInWithFacebook(context);
  //   // Fluttertoast.showToast(
  //   //     msg: "Facebook Signed In successfully!",
  //   //     toastLength: Toast.LENGTH_SHORT,
  //   //     gravity: ToastGravity.BOTTOM,
  //   //     timeInSecForIosWeb: 5,
  //   //     backgroundColor: Colors.orange,
  //   //     textColor: Colors.white,
  //   //     fontSize: 16.0);
  // }
  @override
  Widget build(BuildContext context) {
    final devicewidth = MediaQuery.of(context).size.width;
    final deviceheight = MediaQuery.of(context).size.height;
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          elevation: 0.0,
          title: Row(children: [
            Spacer(),
            InkWell(
              onTap: () {
                // String logMessage = "Skipped Facebook photos";
                // logger.i(logMessage);

                // ScaffoldMessenger.of(context).showSnackBar(
                //   SnackBar(content: Text(logMessage)),
                // );
                Fluttertoast.showToast(
                    msg: "Skipped Facebook Photos",
                    toastLength: Toast.LENGTH_SHORT,
                    gravity: ToastGravity.BOTTOM,
                    timeInSecForIosWeb: 5,
                    backgroundColor: Colors.orange,
                    textColor: Colors.white,
                    fontSize: 16.0);
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: ((context) => GooglePhotos(analytics: widget.analytics
                            //  photos1: photos,
                            ))));
                //             Navigator.push(
                // context,
                // MaterialPageRoute(
                //     builder: ((context) =>  GetPhotosFromLocalStorage(

                //         ))));
              },
              child: Text(
                'Skip',
                style: TextStyle(color: Colors.black),
                textAlign: TextAlign.right,
              ),
            ),
          ]),
          automaticallyImplyLeading: false,
          backgroundColor: Colors.white,
        ),
        backgroundColor: Colors.white,
        body: Column(children: [
          Center(
            child: Container(
              height: deviceheight * 0.4424,
              width: devicewidth * 0.6944,
              child: Image.asset(
                'assets/images/Logo.jpeg',
                fit: BoxFit.fill,
              ),
            ),
          ),
          SizedBox(
            height: 0.0295 * deviceheight,
          ),
          Padding(
            padding: EdgeInsets.all(0.0442 * deviceheight),
            child: ElevatedButton.icon(
              onPressed: () {
               // signInWithFacebook(context, ref);
              },
              icon: Image.asset(
                Constants.facebookPath,
                width: devicewidth * 0.0972,
              ),
              label: Text(
                'Login with Facebook',
                style: TextStyle(
                    fontSize: deviceheight * 0.0265, color: Colors.black),
              ),
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  //backgroundColor: const Color.fromARGB(255, 240, 175, 89),
                  minimumSize: Size(double.infinity, deviceheight * 0.0737),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(0.0295 * deviceheight),
                    side: BorderSide(
                      color: Color.fromARGB(255, 245, 166, 75),
                    ),
                  )),
            ),
          ),
        ]),
      ),
    );
  }
}