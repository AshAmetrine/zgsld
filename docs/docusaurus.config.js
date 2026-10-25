const apiDocsUrl = 'pathname:///zgsld/zig/';

module.exports = {
  title: 'ZGSLD',
  tagline: 'Zig Greeter and Session Launcher Daemon',
  url: 'https://ashametrine.github.io',
  baseUrl: '/zgsld/',
  trailingSlash: true,
  organizationName: 'ashametrine',
  projectName: 'zgsld',
  onBrokenLinks: 'throw',
  staticDirectories: [],
  presets: [
    ['classic', {
      docs: {
        path: 'content',
        routeBasePath: '/',
        sidebarPath: './sidebars.js',
        editUrl: 'https://github.com/ashametrine/zgsld/edit/main/docs/',
      },
      blog: false,
      pages: false,
    }],
  ],
  themeConfig: {
    colorMode: {
      defaultMode: 'dark',
      respectPrefersColorScheme: false,
    },
    navbar: {
      title: 'ZGSLD',
      items: [
        {type: 'docSidebar', sidebarId: 'guide', label: 'Guide', position: 'left'},
        {href: apiDocsUrl, label: 'API', position: 'left'},
        {href: 'https://github.com/ashametrine/zgsld', label: 'GitHub', position: 'right'},
      ],
    },
    prism: {
      additionalLanguages: ['zig', 'nix', 'ini', 'bash'],
    },
  },
};
