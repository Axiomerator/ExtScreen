import 'package:extscreen/destination_pages.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' show kTabScrollDuration;

void main() {
  testWidgets('destinations slide in both directions and can be retargeted', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_pages(0));
    final first = find.text('Page 0');
    final second = find.text('Page 1');
    expect(tester.getTopLeft(first).dx, 0);

    await tester.pumpWidget(_pages(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getTopLeft(first).dx, inExclusiveRange(-500, 0));
    expect(tester.getTopLeft(second).dx, inExclusiveRange(0, 500));

    final interrupted = tester.getTopLeft(first).dx;
    await tester.pumpWidget(_pages(0));
    expect(tester.getTopLeft(first).dx, closeTo(interrupted, 0.01));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getTopLeft(first).dx, inExclusiveRange(interrupted, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(first).dx, 0);
    expect(second, findsNothing);
  });

  testWidgets('resizing during a slide settles at the selected destination', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(350, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_pages(0));
    await tester.pumpWidget(_pages(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getTopLeft(find.text('Page 1')).dx, greaterThan(0));

    tester.view.physicalSize = const Size(900, 700);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Page 1')).dx, 0);
    expect(find.text('Page 0'), findsNothing);
  });

  testWidgets('reduced motion skips the slide and preserves page scroll', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(350, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_pages(0, scroll: true));
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -220),
    );
    await tester.pumpAndSettle();
    final offset = tester.getTopLeft(find.text('Page 0')).dy;
    expect(offset, lessThan(0));

    await tester.pumpWidget(_pages(1, scroll: true));
    await tester.pump();
    await tester.pump(kTabScrollDuration ~/ 3);
    expect(tester.getTopLeft(find.text('Page 1')).dx, greaterThan(0));
    await tester.pumpWidget(_pages(1, reducedMotion: true, scroll: true));
    await tester.pump();
    expect(tester.getTopLeft(find.text('Page 1')).dx, 0);
    expect(tester.getTopLeft(find.text('Page 1')).dy, 0);

    await tester.pumpWidget(_pages(0, reducedMotion: true, scroll: true));
    await tester.pump();
    expect(tester.getTopLeft(find.text('Page 0')).dx, 0);
    expect(tester.getTopLeft(find.text('Page 0')).dy, offset);
  });
}

final _bucket = PageStorageBucket();

Widget _pages(int index, {bool reducedMotion = false, bool scroll = false}) =>
    Builder(
      builder: (context) => MediaQuery(
        data: MediaQueryData.fromView(View.of(context))
            .copyWith(disableAnimations: reducedMotion),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: PageStorage(
            bucket: _bucket,
            child: DestinationPages(
              index: index,
              itemCount: 2,
              itemBuilder: (context, page) {
                final label = Text('Page $page');
                if (!scroll) {
                  return Align(alignment: Alignment.topLeft, child: label);
                }
                return SingleChildScrollView(
                  key: PageStorageKey(page),
                  child: SizedBox(
                    height: 1500,
                    child: Align(alignment: Alignment.topLeft, child: label),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
