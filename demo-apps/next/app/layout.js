export const metadata = { title: 'dx demo' };

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: 'ui-monospace, monospace', whiteSpace: 'pre' }}>{children}</body>
    </html>
  );
}
