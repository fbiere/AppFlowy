import 'dart:async';

import 'package:appflowy/env/env.dart';
import 'package:appflowy/user/application/auth/appflowy_auth_service.dart';
import 'package:appflowy/user/application/auth/auth_service.dart';
import 'package:appflowy/user/application/user_service.dart';
import 'package:appflowy_backend/dispatch/dispatch.dart';
import 'package:appflowy_backend/log.dart';
import 'package:appflowy_backend/protobuf/flowy-error/errors.pb.dart';
import 'package:appflowy_backend/protobuf/flowy-user/protobuf.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_error.dart';

// can't use underscore here.
const loginCallback = 'io.appflowy.appflowy-flutter://login-callback';

class SupabaseAuthService implements AuthService {
  SupabaseAuthService();

  SupabaseClient get _client => Supabase.instance.client;
  GoTrueClient get _auth => _client.auth;

  final AppFlowyAuthService _appFlowyAuthService = AppFlowyAuthService();

  @override
  Future<Either<FlowyError, UserProfilePB>> signUp({
    required String name,
    required String email,
    required String password,
    AuthTypePB authType = AuthTypePB.Supabase,
    Map<String, String> map = const {},
  }) async {
    if (!isSupabaseEnabled) {
      return _appFlowyAuthService.signUp(
        name: name,
        email: email,
        password: password,
      );
    }

    // fetch the uuid from supabase.
    final response = await _auth.signUp(
      email: email,
      password: password,
    );
    final uuid = response.user?.id;
    if (uuid == null) {
      return left(AuthError.supabaseSignUpError);
    }
    // assign the uuid to our backend service.
    //  and will transfer this logic to backend later.
    return _appFlowyAuthService.signUp(
      name: name,
      email: email,
      password: password,
      authType: authType,
      map: {
        AuthServiceMapKeys.uuid: uuid,
      },
    );
  }

  @override
  Future<Either<FlowyError, UserProfilePB>> signIn({
    required String email,
    required String password,
    AuthTypePB authType = AuthTypePB.Supabase,
    Map<String, String> map = const {},
  }) async {
    if (!isSupabaseEnabled) {
      return _appFlowyAuthService.signIn(
        email: email,
        password: password,
      );
    }

    try {
      final response = await _auth.signInWithPassword(
        email: email,
        password: password,
      );
      final uuid = response.user?.id;
      if (uuid == null) {
        return Left(AuthError.supabaseSignInError);
      }
      return _appFlowyAuthService.signIn(
        email: email,
        password: password,
        authType: authType,
        map: {
          AuthServiceMapKeys.uuid: uuid,
        },
      );
    } on AuthException catch (e) {
      Log.error(e);
      return Left(AuthError.supabaseSignInError);
    }
  }

  @override
  Future<Either<FlowyError, UserProfilePB>> signUpWithOAuth({
    required String platform,
    AuthTypePB authType = AuthTypePB.Supabase,
    Map<String, String> map = const {},
  }) async {
    if (!isSupabaseEnabled) {
      return _appFlowyAuthService.signUpWithOAuth(platform: platform);
    }
    final provider = platform.toProvider();
    final completer = supabaseLoginCompleter(
      onSuccess: (userId, userEmail) async {
        return await setupAuth(
          map: {
            AuthServiceMapKeys.uuid: userId,
            AuthServiceMapKeys.email: userEmail
          },
        );
      },
    );

    final response = await _auth.signInWithOAuth(
      provider,
      queryParams: queryParamsForProvider(provider),
      redirectTo: loginCallback,
    );
    if (!response) {
      completer.complete(left(AuthError.supabaseSignInWithOauthError));
    }
    return completer.future;
  }

  @override
  Future<void> signOut({
    AuthTypePB authType = AuthTypePB.Supabase,
  }) async {
    if (isSupabaseEnabled) {
      await _auth.signOut();
    }
    await _appFlowyAuthService.signOut(
      authType: authType,
    );
  }

  @override
  Future<Either<FlowyError, UserProfilePB>> signUpAsGuest({
    AuthTypePB authType = AuthTypePB.Supabase,
    Map<String, String> map = const {},
  }) async {
    // supabase don't support guest login.
    // so, just forward to our backend.
    return _appFlowyAuthService.signUpAsGuest();
  }

  @override
  Future<Either<FlowyError, UserProfilePB>> signInWithMagicLink({
    required String email,
    Map<String, String> map = const {},
  }) async {
    final completer = supabaseLoginCompleter(
      onSuccess: (userId, userEmail) async {
        return await setupAuth(
          map: {
            AuthServiceMapKeys.uuid: userId,
            AuthServiceMapKeys.email: userEmail
          },
        );
      },
    );

    await _auth.signInWithOtp(
      email: email,
      emailRedirectTo: kIsWeb ? null : loginCallback,
    );
    return completer.future;
  }

  @override
  Future<Either<FlowyError, UserProfilePB>> getUser() async {
    return UserBackendService.getCurrentUserProfile();
  }

  Future<Either<FlowyError, User>> getSupabaseUser() async {
    final user = _auth.currentUser;
    if (user == null) {
      return left(AuthError.supabaseGetUserError);
    }
    return Right(user);
  }

  Future<Either<FlowyError, UserProfilePB>> setupAuth({
    required Map<String, String> map,
  }) async {
    final payload = ThirdPartyAuthPB(
      authType: AuthTypePB.Supabase,
      map: map,
    );
    return UserEventThirdPartyAuth(payload)
        .send()
        .then((value) => value.swap());
  }
}

extension on String {
  Provider toProvider() {
    switch (this) {
      case 'github':
        return Provider.github;
      case 'google':
        return Provider.google;
      case 'discord':
        return Provider.discord;
      default:
        throw UnimplementedError();
    }
  }
}

/// Creates a completer that listens to Supabase authentication state changes and
/// completes when a user signs in.
///
/// This function sets up a listener on Supabase's authentication state. When a user
/// signs in, it triggers the provided [onSuccess] callback with the user's `id` and
/// `email`. Once the [onSuccess] callback is executed and a response is received,
/// the completer completes with the response, and the listener is canceled.
///
/// Parameters:
/// - [onSuccess]: A callback function that's executed when a user signs in. It
///   should take in a user's `id` and `email` and return a `Future` containing either
///   a `FlowyError` or a `UserProfilePB`.
///
/// Returns:
/// A completer of type `Either<FlowyError, UserProfilePB>`. This completer completes
/// with the response from the [onSuccess] callback when a user signs in.
Completer<Either<FlowyError, UserProfilePB>> supabaseLoginCompleter({
  required Future<Either<FlowyError, UserProfilePB>> Function(
    String userId,
    String userEmail,
  ) onSuccess,
}) {
  final completer = Completer<Either<FlowyError, UserProfilePB>>();
  late final StreamSubscription<AuthState> subscription;
  final auth = Supabase.instance.client.auth;

  subscription = auth.onAuthStateChange.listen((event) async {
    final user = event.session?.user;
    if (event.event == AuthChangeEvent.signedIn && user != null) {
      final response = await onSuccess(
        user.id,
        user.email ?? user.newEmail ?? '',
      );
      // Only cancle the subscription if the Event is signedIn.
      subscription.cancel();
      completer.complete(response);
    }
  });
  return completer;
}

Map<String, String> queryParamsForProvider(Provider provider) {
  switch (provider) {
    case Provider.github:
      return {};
    case Provider.google:
      return {
        'access_type': 'offline',
        'prompt': 'consent',
      };
    case Provider.discord:
      return {};
    default:
      return {};
  }
}
