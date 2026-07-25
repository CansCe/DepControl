import 'package:dart_frog/dart_frog.dart';

Response onRequest(RequestContext context) {
  return Response.json(
    body: {
      'service': 'depcontrol-api',
      'status': 'ok',
      'endpoints': [
        'GET  /projects',
        'POST /projects            {gitUrl, ref?}',
        'GET  /projects/<id>       -> dependency report',
        'POST /projects/<id>/resolve {package, targetConstraint}',
      ],
    },
  );
}
